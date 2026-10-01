SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_RegistrarCliente]
    @Nit nvarchar(100),
    @RazonSocial nvarchar(500),
    @Estado varchar(20) = 'ACTIVO'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NitNormalizado nvarchar(100) = UPPER(NULLIF(LTRIM(RTRIM(@Nit)), N''));
    DECLARE @RazonSocialNormalizada nvarchar(500) = NULLIF(LTRIM(RTRIM(@RazonSocial)), N'');
    DECLARE @EstadoNormalizado varchar(20) = UPPER(NULLIF(LTRIM(RTRIM(@Estado)), ''));
    DECLARE @ClienteID bigint;
    DECLARE @NitExistente nvarchar(20);
    DECLARE @RazonSocialExistente nvarchar(300);
    DECLARE @EstadoExistente varchar(10);
    DECLARE @Resultado varchar(30);
    DECLARE @Creado bit;
    DECLARE @RequiereRevision bit;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @NitNormalizado IS NULL
        THROW 50101, 'El NIT es obligatorio.', 1;

    IF LEN(@NitNormalizado) > 20
        THROW 50102, 'El NIT no puede superar 20 caracteres.', 1;

    IF @RazonSocialNormalizada IS NULL
        THROW 50103, 'La razón social es obligatoria.', 1;

    IF LEN(@RazonSocialNormalizada) > 300
        THROW 50104, 'La razón social no puede superar 300 caracteres.', 1;

    IF @EstadoNormalizado IS NULL
        SET @EstadoNormalizado = 'ACTIVO';

    IF @EstadoNormalizado NOT IN ('ACTIVO', 'INACTIVO')
        THROW 50105, 'El estado debe ser ACTIVO o INACTIVO.', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N'dian:cliente:nit:', @NitNormalizado);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50106, 'No fue posible obtener el bloqueo para registrar el cliente.', 1;

    SELECT
        @ClienteID = [ClienteID],
        @NitExistente = [Nit],
        @RazonSocialExistente = [RazonSocial],
        @EstadoExistente = [Estado]
    FROM [dian].[Cliente] WITH (UPDLOCK, HOLDLOCK)
    WHERE [Nit] = CONVERT(nvarchar(20), @NitNormalizado);

    IF @ClienteID IS NULL
    BEGIN
        INSERT INTO [dian].[Cliente]
        (
            [Nit],
            [RazonSocial],
            [Estado]
        )
        VALUES
        (
            CONVERT(nvarchar(20), @NitNormalizado),
            CONVERT(nvarchar(300), @RazonSocialNormalizada),
            CONVERT(varchar(10), @EstadoNormalizado)
        );

        SET @ClienteID = SCOPE_IDENTITY();
        SET @NitExistente = CONVERT(nvarchar(20), @NitNormalizado);
        SET @RazonSocialExistente = CONVERT(nvarchar(300), @RazonSocialNormalizada);
        SET @EstadoExistente = CONVERT(varchar(10), @EstadoNormalizado);
        SET @Resultado = 'NUEVO';
        SET @Creado = 1;
        SET @RequiereRevision = 0;
    END
    ELSE IF @RazonSocialExistente = CONVERT(nvarchar(300), @RazonSocialNormalizada)
        AND @EstadoExistente = CONVERT(varchar(10), @EstadoNormalizado)
    BEGIN
        SET @Resultado = 'EXISTENTE';
        SET @Creado = 0;
        SET @RequiereRevision = 0;
    END
    ELSE
    BEGIN
        SET @Resultado = 'REQUIERE_REVISION';
        SET @Creado = 0;
        SET @RequiereRevision = 1;
    END;

    COMMIT TRANSACTION;

    SELECT
        @ClienteID AS [ClienteID],
        @NitExistente AS [Nit],
        @RazonSocialExistente AS [RazonSocial],
        @EstadoExistente AS [Estado],
        @Resultado AS [Resultado],
        @Creado AS [Creado],
        @RequiereRevision AS [RequiereRevision];
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarCliente] TO [dian_runtime];
GO
