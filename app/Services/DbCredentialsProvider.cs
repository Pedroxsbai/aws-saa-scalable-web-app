using System.Text.Json;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;

namespace AwsSaaApp.Services;

public sealed record DbCredentials(string Username, string Password);

/// <summary>
/// Résout les identifiants PostgreSQL. En production (EC2), lit le secret
/// géré par RDS via Secrets Manager (DB_SECRET_ARN) — jamais un fichier de
/// config. En développement local, DB_USERNAME/DB_PASSWORD suffisent : pas
/// d'accès AWS requis pour lancer l'app sur un poste de dev.
/// </summary>
public sealed class DbCredentialsProvider
{
    private readonly IAmazonSecretsManager? _secretsManager;
    private readonly string? _secretArn;
    private readonly string? _devUsername;
    private readonly string? _devPassword;

    // Le secret RDS peut tourner (rotation automatique) ; un cache figé au
    // démarrage casserait l'app après la première rotation. 5 minutes limite
    // le taux d'appel à Secrets Manager sans re-résoudre à chaque requête.
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);
    private DbCredentials? _cached;
    private DateTimeOffset _cachedAt = DateTimeOffset.MinValue;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public DbCredentialsProvider(IConfiguration configuration, IAmazonSecretsManager? secretsManager)
    {
        _secretArn = configuration["DB_SECRET_ARN"];
        _devUsername = configuration["DB_USERNAME"];
        _devPassword = configuration["DB_PASSWORD"];
        _secretsManager = secretsManager;
    }

    public async Task<DbCredentials> GetCredentialsAsync(CancellationToken ct)
    {
        if (!string.IsNullOrEmpty(_devUsername) && !string.IsNullOrEmpty(_devPassword))
        {
            return new DbCredentials(_devUsername, _devPassword);
        }

        if (string.IsNullOrEmpty(_secretArn) || _secretsManager is null)
        {
            throw new InvalidOperationException(
                "Aucune source d'identifiants configurée : ni DB_SECRET_ARN (production), " +
                "ni DB_USERNAME/DB_PASSWORD (développement local).");
        }

        if (_cached is not null && DateTimeOffset.UtcNow - _cachedAt < CacheTtl)
        {
            return _cached;
        }

        await _lock.WaitAsync(ct);
        try
        {
            // Un autre thread a peut-être déjà rafraîchi pendant l'attente.
            if (_cached is not null && DateTimeOffset.UtcNow - _cachedAt < CacheTtl)
            {
                return _cached;
            }

            var response = await _secretsManager.GetSecretValueAsync(
                new GetSecretValueRequest { SecretId = _secretArn }, ct);

            using var doc = JsonDocument.Parse(response.SecretString);
            var username = doc.RootElement.GetProperty("username").GetString()
                ?? throw new InvalidOperationException("Secret RDS sans champ \"username\".");
            var password = doc.RootElement.GetProperty("password").GetString()
                ?? throw new InvalidOperationException("Secret RDS sans champ \"password\".");

            _cached = new DbCredentials(username, password);
            _cachedAt = DateTimeOffset.UtcNow;
            return _cached;
        }
        finally
        {
            _lock.Release();
        }
    }
}
