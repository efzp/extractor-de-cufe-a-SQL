SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
    EXEC [dian].[sp_RegistrarCliente]
        @Nit = N' ',
        @RazonSocial = N'Cliente inválido';

    THROW 51105, 'El procedimiento aceptó un NIT vacío.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50101
        THROW;
END CATCH;

BEGIN TRY
    EXEC [dian].[sp_RegistrarCliente]
        @Nit = N'900123456',
        @RazonSocial = N'Cliente inválido',
        @Estado = 'PENDIENTE';

    THROW 51106, 'El procedimiento aceptó un estado inválido.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50105
        THROW;
END CATCH;
GO

BEGIN TRANSACTION;
GO

DECLARE @NitPrueba nvarchar(20) = CONCAT(N'T', LEFT(REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N''), 19));
DECLARE @ClienteID bigint;
DECLARE @ClienteExistenteID bigint;
DECLARE @Resultado varchar(30);
DECLARE @Creado bit;
DECLARE @RequiereRevision bit;
DECLARE @ResultadoTabla TABLE
(
    [ClienteID] bigint,
    [Nit] nvarchar(20),
    [RazonSocial] nvarchar(300),
    [Estado] varchar(10),
    [Resultado] varchar(30),
    [Creado] bit,
    [RequiereRevision] bit
);

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_RegistrarCliente]
    @Nit = @NitPrueba,
    @RazonSocial = N'Cliente de prueba',
    @Estado = 'ACTIVO';

SELECT
    @ClienteID = [ClienteID],
    @Resultado = [Resultado],
    @Creado = [Creado],
    @RequiereRevision = [RequiereRevision]
FROM @ResultadoTabla;

IF @ClienteID IS NULL
   OR @Resultado <> 'NUEVO'
   OR @Creado <> 1
   OR @RequiereRevision <> 0
    THROW 51101, 'La primera llamada no creó correctamente el cliente.', 1;

DELETE FROM @ResultadoTabla;

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_RegistrarCliente]
    @Nit = @NitPrueba,
    @RazonSocial = N'Cliente de prueba',
    @Estado = 'ACTIVO';

SELECT
    @ClienteExistenteID = [ClienteID],
    @Resultado = [Resultado],
    @Creado = [Creado],
    @RequiereRevision = [RequiereRevision]
FROM @ResultadoTabla;

IF @ClienteExistenteID <> @ClienteID
   OR @Resultado <> 'EXISTENTE'
   OR @Creado <> 0
   OR @RequiereRevision <> 0
    THROW 51102, 'La segunda llamada no devolvió el cliente existente.', 1;

DELETE FROM @ResultadoTabla;

INSERT INTO @ResultadoTabla
EXEC [dian].[sp_RegistrarCliente]
    @Nit = @NitPrueba,
    @RazonSocial = N'Razón social diferente',
    @Estado = 'ACTIVO';

SELECT
    @ClienteExistenteID = [ClienteID],
    @Resultado = [Resultado],
    @Creado = [Creado],
    @RequiereRevision = [RequiereRevision]
FROM @ResultadoTabla;

IF @ClienteExistenteID <> @ClienteID
   OR @Resultado <> 'REQUIERE_REVISION'
   OR @Creado <> 0
   OR @RequiereRevision <> 1
    THROW 51103, 'La diferencia de datos no fue enviada a revisión.', 1;

IF EXISTS
(
    SELECT 1
    FROM [dian].[Cliente]
    WHERE [ClienteID] = @ClienteID
      AND [RazonSocial] <> N'Cliente de prueba'
)
    THROW 51104, 'El procedimiento sobrescribió un cliente existente.', 1;

IF (SELECT COUNT(*) FROM [dian].[Cliente] WHERE [Nit] = @NitPrueba) <> 1
    THROW 51107, 'La idempotencia permitió más de un cliente con el mismo NIT.', 1;

SELECT
    'OK' AS [ResultadoPrueba],
    @ClienteID AS [ClienteIDProbado],
    @NitPrueba AS [NitProbado];
GO

ROLLBACK TRANSACTION;
GO
