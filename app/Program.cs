using Amazon.SecretsManager;
using AwsSaaApp.Services;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

// Port d'écoute : var.app_port côté Terraform (8080 par défaut), jamais
// codé en dur — le launch template le passe en variable d'environnement.
var appPort = builder.Configuration["APP_PORT"] ?? "8080";
builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(int.Parse(appPort)));

// Le client Secrets Manager n'est enregistré que si DB_SECRET_ARN est
// présent (chemin production/EC2). En dev local, la résolution de région
// par défaut du SDK échouerait sans identifiants AWS pour rien : on ne le
// construit pas du tout, DbCredentialsProvider bascule sur DB_USERNAME/
// DB_PASSWORD.
//
// Résolu via une factory explicite (GetService, pas GetRequiredService) :
// l'injection de constructeur classique ignore les annotations "nullable"
// de C# à l'exécution et exigerait quand même une inscription, même pour
// un paramètre IAmazonSecretsManager?.
if (!string.IsNullOrEmpty(builder.Configuration["DB_SECRET_ARN"]))
{
    builder.Services.AddSingleton<IAmazonSecretsManager>(new AmazonSecretsManagerClient());
}

builder.Services.AddSingleton(sp => new DbCredentialsProvider(
    sp.GetRequiredService<IConfiguration>(),
    sp.GetService<IAmazonSecretsManager>()));

var app = builder.Build();

app.MapGet("/", () => Results.Ok(new
{
    app = "aws-saa-manara",
    status = "running",
}));

// Health check ALB : doit rester rapide et sans dépendance externe.
// L'ALB l'appelle toutes les 30 secondes sur chaque instance de l'ASG.
app.MapGet("/health", () => Results.Ok("healthy"));

// Vérifie la connectivité RDS de bout en bout : instance privée -> secret
// Secrets Manager -> connexion PostgreSQL -> requête triviale. Sert à
// démontrer que le chemin réseau privé fonctionne, pas un health check ALB
// (trop lent/coûteux pour être appelé toutes les 30 secondes).
app.MapGet("/db-check", async (
    DbCredentialsProvider credentialsProvider,
    IConfiguration configuration,
    CancellationToken ct) =>
{
    var host = configuration["DB_HOST"] ?? "localhost";
    var port = configuration["DB_PORT"] ?? "5432";
    var dbName = configuration["DB_NAME"] ?? "appdb";

    try
    {
        var credentials = await credentialsProvider.GetCredentialsAsync(ct);

        var connectionString = new NpgsqlConnectionStringBuilder
        {
            Host = host,
            Port = int.Parse(port),
            Database = dbName,
            Username = credentials.Username,
            Password = credentials.Password,
            Timeout = 3,
            CommandTimeout = 3,
            SslMode = SslMode.Require,
        }.ConnectionString;

        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(ct);

        await using var command = new NpgsqlCommand("SELECT 1", connection);
        await command.ExecuteScalarAsync(ct);

        stopwatch.Stop();

        return Results.Ok(new
        {
            status = "ok",
            host,
            database = dbName,
            latency_ms = stopwatch.ElapsedMilliseconds,
        });
    }
    catch (Exception ex)
    {
        return Results.Json(
            new { status = "error", host, database = dbName, error = ex.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

app.Run();
