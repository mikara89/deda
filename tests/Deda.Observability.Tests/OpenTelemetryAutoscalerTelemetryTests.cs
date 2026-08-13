using Deda.Core;
using Deda.Observability;
using Microsoft.Extensions.Logging.Abstractions;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Deda.Observability.Tests;

public sealed class OpenTelemetryAutoscalerTelemetryTests
{
    [Fact]
    public void DecisionsAndTriggerResultsEmitStandardMetricsWithDimensions()
    {
        var measurements = new ConcurrentBag<Measurement>();
        using var listener = CreateMeterListener(measurements);
        var telemetry = new OpenTelemetryAutoscalerTelemetry(
            NullLogger<OpenTelemetryAutoscalerTelemetry>.Instance);

        telemetry.RecordTrigger(
            "orders",
            "rabbitmq",
            TimeSpan.FromMilliseconds(250),
            TriggerResult.Ok(42));
        telemetry.RecordDecision(new ScaleDecision(
            "service-1",
            "orders",
            1,
            5,
            42,
            "test",
            DateTimeOffset.UtcNow));
        telemetry.RecordReconcile(TimeSpan.FromMilliseconds(500), success: true);

        Assert.Contains(measurements, measurement =>
            measurement.Name == "deda_trigger_requests_total" &&
            Equals(measurement.Tags["service"], "orders") &&
            Equals(measurement.Tags["trigger"], "rabbitmq") &&
            Equals(measurement.Tags["result"], "success"));
        Assert.Contains(measurements, measurement =>
            measurement.Name == "deda_scale_events_total" &&
            Equals(measurement.Tags["direction"], "up"));
        Assert.Contains(measurements, measurement =>
            measurement.Name == "deda_reconcile_duration_seconds" &&
            Math.Abs(measurement.Value - 0.5) < 0.001);
    }

    [Fact]
    public void OperationsCreateNestedActivitiesAndErrorsSetStatus()
    {
        var activities = new List<Activity>();
        using var listener = new ActivityListener
        {
            ShouldListenTo = source => source.Name == DedaDiagnostics.SourceName,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllData,
            ActivityStopped = activity => activities.Add(activity),
        };
        ActivitySource.AddActivityListener(listener);
        var telemetry = new OpenTelemetryAutoscalerTelemetry(
            NullLogger<OpenTelemetryAutoscalerTelemetry>.Instance);

        using (telemetry.StartOperation("reconcile"))
        {
            using (telemetry.StartOperation("trigger", "orders", "rabbitmq"))
            {
                telemetry.RecordError("orders", "trigger", new IOException("unavailable"));
            }
        }

        var reconcile = Assert.Single(activities, activity => activity.OperationName == "reconcile");
        var trigger = Assert.Single(activities, activity => activity.OperationName == "trigger");
        Assert.Equal(reconcile.TraceId, trigger.TraceId);
        Assert.Equal(reconcile.SpanId, trigger.ParentSpanId);
        Assert.Equal(ActivityStatusCode.Error, trigger.Status);
        Assert.Equal("orders", trigger.GetTagItem("service.name"));
    }

    private static MeterListener CreateMeterListener(ConcurrentBag<Measurement> measurements)
    {
        var listener = new MeterListener
        {
            InstrumentPublished = (instrument, meterListener) =>
            {
                if (instrument.Meter.Name == DedaDiagnostics.SourceName)
                    meterListener.EnableMeasurementEvents(instrument);
            },
        };
        listener.SetMeasurementEventCallback<long>((instrument, value, tags, _) =>
            measurements.Add(new Measurement(instrument.Name, value, CopyTags(tags))));
        listener.SetMeasurementEventCallback<double>((instrument, value, tags, _) =>
            measurements.Add(new Measurement(instrument.Name, value, CopyTags(tags))));
        listener.SetMeasurementEventCallback<int>((instrument, value, tags, _) =>
            measurements.Add(new Measurement(instrument.Name, value, CopyTags(tags))));
        listener.Start();
        return listener;
    }

    private static Dictionary<string, object?> CopyTags(ReadOnlySpan<KeyValuePair<string, object?>> tags)
    {
        var copy = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var tag in tags)
            copy[tag.Key] = tag.Value;
        return copy;
    }

    private sealed record Measurement(
        string Name,
        double Value,
        IReadOnlyDictionary<string, object?> Tags);
}
