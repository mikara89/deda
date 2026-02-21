using Deda.Core;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Deda.Swarm
{
    public sealed class DockerEngineSwarmServiceClient : ISwarmServiceClient, IDisposable
    {
        private readonly HttpClient _http;
        private static readonly DockerEngineJsonContext JsonCtx = DockerEngineJsonContext.Default;

        public DockerEngineSwarmServiceClient(HttpClient httpClient)
        {
            _http = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        }

        public async Task<IReadOnlyList<ServiceRef>> ListServicesAsync(CancellationToken ct)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, "services");
            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);

            await EnsureSuccess(resp).ConfigureAwait(false);

            await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            var items = await JsonSerializer.DeserializeAsync<List<ServiceListItemDto>>(stream, JsonCtx.ListServiceListItemDto, ct)
                .ConfigureAwait(false);

            items ??= new List<ServiceListItemDto>();

            var list = new List<ServiceRef>(items.Count);
            foreach (var it in items)
            {
                if (it?.Id is null) continue;
                list.Add(ToServiceRef(it.Id, it.Version?.Index ?? 0, it.Spec));
            }
            return list;
        }

        public async Task<ServiceRef> GetServiceAsync(string serviceId, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(serviceId))
                throw new ArgumentException("serviceId empty", nameof(serviceId));

            using var req = new HttpRequestMessage(HttpMethod.Get, $"services/{Uri.EscapeDataString(serviceId)}");
            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);

            await EnsureSuccess(resp).ConfigureAwait(false);

            await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            var dto = await JsonSerializer.DeserializeAsync<ServiceInspectDto>(stream, JsonCtx.ServiceInspectDto, ct).ConfigureAwait(false);

            if (dto?.Id is null || dto.Spec is null)
                throw new InvalidOperationException("Invalid Docker service inspect response.");

            return ToServiceRef(dto.Id, dto.Version?.Index ?? 0, dto.Spec);
        }

        public async Task UpdateReplicasAsync(string serviceId, long versionIndex, int desiredReplicas, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(serviceId))
                throw new ArgumentException("serviceId empty", nameof(serviceId));
            if (desiredReplicas < 0)
                throw new ArgumentOutOfRangeException(nameof(desiredReplicas));

            // Inspect to get full Spec (so we don't drop fields)
            var inspected = await InspectRaw(serviceId, ct).ConfigureAwait(false);

            if (inspected.Spec is null)
                throw new InvalidOperationException("Service spec missing.");

            inspected.Spec.Mode ??= new ServiceModeDto();
            inspected.Spec.Mode.Replicated ??= new ReplicatedServiceDto();
            inspected.Spec.Mode.Replicated.Replicas = desiredReplicas;

            // If it is global, this is not supported by replicas scaling
            if (IsGlobal(inspected.Spec))
                throw new NotSupportedException("Cannot scale a global-mode service by replicas.");

            var bodyJson = JsonSerializer.Serialize(inspected.Spec, JsonCtx.ServiceSpecDto);
            using var req = new HttpRequestMessage(HttpMethod.Post,
                $"services/{Uri.EscapeDataString(serviceId)}/update?version={versionIndex}")
            {
                Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
            };

            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);

            if (resp.IsSuccessStatusCode)
                return;

            // Swarm optimistic concurrency conflict:
            // Docker often returns 400 with message "update out of sequence"
            var err = await SafeReadBody(resp, ct).ConfigureAwait(false);
            if ((resp.StatusCode == HttpStatusCode.BadRequest || resp.StatusCode == HttpStatusCode.Conflict) &&
                err.Contains("update out of sequence", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("version conflict");
            }

            throw new HttpRequestException($"Docker update failed: {(int)resp.StatusCode} {resp.ReasonPhrase} {Trim(err, 200)}");
        }

        private async Task<ServiceInspectDto> InspectRaw(string serviceId, CancellationToken ct)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"services/{Uri.EscapeDataString(serviceId)}");
            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);

            await EnsureSuccess(resp).ConfigureAwait(false);

            await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            var dto = await JsonSerializer.DeserializeAsync<ServiceInspectDto>(stream, JsonCtx.ServiceInspectDto, ct).ConfigureAwait(false);

            if (dto?.Id is null)
                throw new InvalidOperationException("Invalid Docker service inspect response.");

            return dto;
        }

        private static ServiceRef ToServiceRef(string id, long versionIndex, ServiceSpecDto? spec)
        {
            var name = spec?.Name ?? id;

            var labels = (IReadOnlyDictionary<string, string>)
                (spec?.Labels ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase));

            var mode = SwarmServiceMode.Unknown;
            int replicas = 0;

            if (spec?.Mode?.Replicated is not null)
            {
                mode = SwarmServiceMode.Replicated;
                replicas = (int)(spec.Mode.Replicated.Replicas ?? 0);
            }
            else if (spec?.Mode?.Global is not null)
            {
                mode = SwarmServiceMode.Global;
                replicas = 0;
            }

            return new ServiceRef(
                ServiceId: id,
                Name: name,
                CurrentReplicas: replicas,
                Labels: labels,
                VersionIndex: versionIndex,
                Mode: mode
            );
        }

        private static bool IsGlobal(ServiceSpecDto spec)
            => spec.Mode?.Global is not null;

        private static async Task EnsureSuccess(HttpResponseMessage resp)
        {
            if (resp.IsSuccessStatusCode) return;

            var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            throw new HttpRequestException($"Docker API error {(int)resp.StatusCode} {resp.ReasonPhrase}: {Trim(body, 200)}");
        }

        private static async Task<string> SafeReadBody(HttpResponseMessage resp, CancellationToken ct)
        {
            try { return await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false); }
            catch { return string.Empty; }
        }

        private static string Trim(string s, int max)
            => string.IsNullOrEmpty(s) ? s : (s.Length <= max ? s : s.Substring(0, max) + "...");

        public void Dispose() => _http.Dispose();
    }
}
