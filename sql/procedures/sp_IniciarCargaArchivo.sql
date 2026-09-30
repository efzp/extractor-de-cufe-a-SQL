SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dian].[sp_IniciarCargaArchivo]
    @ClienteID bigint,
    @NombreArchivo nvarchar(260),
    @HashArchivoSha256 varchar(128),
    @SharePointItemID nvarchar(150) = NULL,
    @SharePointUrl nvarchar(1000) = NULL,
    @ETag nvarchar(200) = NULL,
    @NombreTablaOrigen nvarchar(128) = NULL,
    @CargadoPor nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NombreArchivoNormalizado nvarchar(260) = NULLIF(LTRIM(RTRIM(@NombreArchivo)), N'');
    DECLARE @HashNormalizado varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashArchivoSha256)), ''));
    DECLARE @SharePointItemNormalizado nvarchar(150) = NULLIF(LTRIM(RTRIM(@SharePointItemID)), N'');
    DECLARE @ETagNormalizado nvarchar(200) = NULLIF(LTRIM(RTRIM(@ETag)), N'');
    DECLARE @CargaArchivoID bigint;
    DECLARE @CargaOriginalID bigint;
    DECLARE @Estado varchar(30);
    DECLARE @Resultado varchar(30);
    DECLARE @DebeProcesar bit;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF NOT EXISTS
    (
        SELECT 1
        FROM [dian].[Cliente]
        WHERE [ClienteID] = @ClienteID
          AND [Estado] = 'ACTIVO'
    )
        THROW 50001, 'El cliente no existe o no está activo.', 1;

    IF @NombreArchivoNormalizado IS NULL
        THROW 50002, 'El nombre del archivo es obligatorio.', 1;

    IF @HashNormalizado IS NULL
       OR LEN(@HashNormalizado) <> 64
       OR @HashNormalizado COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        THROW 50003, 'El hash del archivo debe ser SHA-256 hexadecimal de 64 caracteres.', 1;

    BEGIN TRANSACTION;

    SET @LockResource = CONCAT(N'dian:carga:', @ClienteID, N':', @HashNormalizado);

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 50004, 'No fue posible obtener el bloqueo para iniciar la carga.', 1;

    IF @SharePointItemNormalizado IS NOT NULL AND @ETagNormalizado IS NOT NULL
    BEGIN
        SELECT TOP (1)
            @CargaArchivoID = [CargaArchivoID],
            @CargaOriginalID = [CargaOriginalID],
            @Estado = [Estado]
        FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ClienteID] = @ClienteID
          AND [SharePointItemID] = @SharePointItemNormalizado
          AND [ETag] = @ETagNormalizado
        ORDER BY [CargaArchivoID];
    END;

    IF @CargaArchivoID IS NOT NULL
    BEGIN
        IF @Estado = 'ERROR'
        BEGIN
            UPDATE [dian].[CargaArchivo]
            SET [Estado] = 'RECIBIDA',
                [FechaInicioUTC] = sysutcdatetime(),
                [FechaFinUTC] = NULL,
                [Mensaje] = N'Reintento solicitado para la misma versión del archivo.'
            WHERE [CargaArchivoID] = @CargaArchivoID;

            SET @Estado = 'RECIBIDA';
            SET @Resultado = 'REINTENTO';
            SET @DebeProcesar = 1;
        END
        ELSE
        BEGIN
            SET @Resultado = 'SOLICITUD_EXISTENTE';
            SET @DebeProcesar = CASE WHEN @Estado = 'RECIBIDA' THEN 1 ELSE 0 END;
        END;

        COMMIT TRANSACTION;

        SELECT
            @CargaArchivoID AS [CargaArchivoID],
            @CargaOriginalID AS [CargaOriginalID],
            @Estado AS [Estado],
            @Resultado AS [Resultado],
            @DebeProcesar AS [DebeProcesar];
        RETURN;
    END;

    DECLARE @EstadoOriginal varchar(30);
    DECLARE @TotalFilasOriginal int;

    SELECT TOP (1)
        @CargaOriginalID = COALESCE([CargaOriginalID], [CargaArchivoID]),
        @EstadoOriginal = [Estado],
        @TotalFilasOriginal = [TotalFilas]
    FROM [dian].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
    WHERE [ClienteID] = @ClienteID
      AND [HashArchivoSha256] = @HashNormalizado
      AND [Estado] <> 'ERROR'
    ORDER BY
        CASE WHEN [Estado] IN ('OK', 'PARCIAL', 'REQUIERE_REVISION') THEN 0 ELSE 1 END,
        [CargaArchivoID];

    IF @CargaOriginalID IS NOT NULL
    BEGIN
        INSERT INTO [dian].[CargaArchivo]
        (
            [ClienteID],
            [CargaOriginalID],
            [NombreArchivo],
            [SharePointItemID],
            [SharePointUrl],
            [ETag],
            [HashArchivoSha256],
            [NombreTablaOrigen],
            [CargadoPor],
            [FechaFinUTC],
            [Estado],
            [TotalFilas],
            [FilasDuplicadas],
            [Mensaje]
        )
        VALUES
        (
            @ClienteID,
            @CargaOriginalID,
            @NombreArchivoNormalizado,
            @SharePointItemNormalizado,
            NULLIF(LTRIM(RTRIM(@SharePointUrl)), N''),
            @ETagNormalizado,
            @HashNormalizado,
            NULLIF(LTRIM(RTRIM(@NombreTablaOrigen)), N''),
            NULLIF(LTRIM(RTRIM(@CargadoPor)), N''),
            sysutcdatetime(),
            'SIN_CAMBIOS',
            @TotalFilasOriginal,
            @TotalFilasOriginal,
            N'El contenido del archivo ya había sido registrado.'
        );

        SET @CargaArchivoID = SCOPE_IDENTITY();
        SET @Estado = 'SIN_CAMBIOS';
        SET @Resultado = 'SIN_CAMBIOS';
        SET @DebeProcesar = 0;
    END
    ELSE
    BEGIN
        INSERT INTO [dian].[CargaArchivo]
        (
            [ClienteID],
            [NombreArchivo],
            [SharePointItemID],
            [SharePointUrl],
            [ETag],
            [HashArchivoSha256],
            [NombreTablaOrigen],
            [CargadoPor],
            [Estado],
            [Mensaje]
        )
        VALUES
        (
            @ClienteID,
            @NombreArchivoNormalizado,
            @SharePointItemNormalizado,
            NULLIF(LTRIM(RTRIM(@SharePointUrl)), N''),
            @ETagNormalizado,
            @HashNormalizado,
            NULLIF(LTRIM(RTRIM(@NombreTablaOrigen)), N''),
            NULLIF(LTRIM(RTRIM(@CargadoPor)), N''),
            'RECIBIDA',
            N'Archivo registrado y pendiente de procesar.'
        );

        SET @CargaArchivoID = SCOPE_IDENTITY();
        SET @Estado = 'RECIBIDA';
        SET @Resultado = 'NUEVA_CARGA';
        SET @DebeProcesar = 1;
    END;

    COMMIT TRANSACTION;

    SELECT
        @CargaArchivoID AS [CargaArchivoID],
        @CargaOriginalID AS [CargaOriginalID],
        @Estado AS [Estado],
        @Resultado AS [Resultado],
        @DebeProcesar AS [DebeProcesar];
END;
GO

GRANT EXECUTE ON OBJECT::[dian].[sp_IniciarCargaArchivo] TO [dian_runtime];
GO
