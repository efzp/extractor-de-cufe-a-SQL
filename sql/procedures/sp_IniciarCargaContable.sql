CREATE OR ALTER PROCEDURE [contabilidad].[sp_IniciarCargaContable]
    @ClienteID bigint,
    @FuenteContable nvarchar(200),
    @NombreArchivo nvarchar(500),
    @NombreHoja nvarchar(256),
    @BlobUri nvarchar(2000),
    @TamanoBytes bigint,
    @HashArchivoSha256 varchar(128),
    @SharePointItemID nvarchar(300) = NULL,
    @SharePointUrl nvarchar(2000) = NULL,
    @ETag nvarchar(400) = NULL,
    @CargadoPor nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Fuente nvarchar(200) = UPPER(NULLIF(LTRIM(RTRIM(@FuenteContable)), N''));
    DECLARE @Nombre nvarchar(500) = NULLIF(LTRIM(RTRIM(@NombreArchivo)), N'');
    DECLARE @Hoja nvarchar(256) = NULLIF(LTRIM(RTRIM(@NombreHoja)), N'');
    DECLARE @Uri nvarchar(2000) = NULLIF(LTRIM(RTRIM(@BlobUri)), N'');
    DECLARE @Hash varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashArchivoSha256)), ''));
    DECLARE @Item nvarchar(300) = NULLIF(LTRIM(RTRIM(@SharePointItemID)), N'');
    DECLARE @Version nvarchar(400) = NULLIF(LTRIM(RTRIM(@ETag)), N'');
    DECLARE @CargaArchivoID bigint;
    DECLARE @HashExistente char(64);
    DECLARE @HojaExistente nvarchar(128);
    DECLARE @Estado varchar(20);
    DECLARE @Resultado varchar(30);
    DECLARE @DebeProcesar bit;
    DECLARE @FilasRegistradas int;
    DECLARE @TotalFilas int;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @ClienteID IS NULL OR @ClienteID <= 0
        THROW 50810, 'ClienteID debe ser positivo.', 1;
    IF @Fuente IS NULL OR LEN(@Fuente) > 80
        THROW 50811, 'FuenteContable es obligatoria y admite hasta 80 caracteres.', 1;
    IF @Nombre IS NULL OR LEN(@Nombre) > 260
       OR @Hoja IS NULL OR LEN(@Hoja) > 128
        THROW 50812, 'NombreArchivo o NombreHoja no valido.', 1;
    IF @Uri IS NULL OR LEN(@Uri) > 1000 OR CHARINDEX(N'?', @Uri) > 0
        THROW 50813, 'BlobUri no valida; no incluya SAS ni parametros.', 1;
    IF @TamanoBytes IS NULL OR @TamanoBytes <= 0
        THROW 50814, 'TamanoBytes debe ser positivo.', 1;
    IF @Hash IS NULL OR LEN(@Hash) <> 64
       OR @Hash COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        THROW 50815, 'HashArchivoSha256 debe ser hexadecimal SHA-256.', 1;
    IF LEN(@Item) > 150 OR LEN(@Version) > 200
       OR LEN(@SharePointUrl) > 1000 OR LEN(@CargadoPor) > 256
        THROW 50816, 'Metadatos de SharePoint demasiado largos.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS
        (
            SELECT 1 FROM [dian].[Cliente]
            WHERE [ClienteID] = @ClienteID AND [Estado] = 'ACTIVO'
        )
            THROW 50817, 'El cliente no existe o no esta activo.', 1;

        SET @LockResource = CONCAT(N'contabilidad:carga:', @ClienteID, N':', @Fuente);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;
        IF @LockResult < 0
            THROW 50818, 'No fue posible bloquear la carga contable.', 1;

        IF @Item IS NOT NULL AND @Version IS NOT NULL
        BEGIN
            SELECT @CargaArchivoID = [CargaArchivoID],
                   @HashExistente = [HashArchivoSha256],
                   @HojaExistente = [NombreHoja],
                   @Estado = [Estado],
                   @TotalFilas = [TotalFilas]
            FROM [contabilidad].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
            WHERE [ClienteID] = @ClienteID
              AND [FuenteContable] = @Fuente
              AND [SharePointItemID] = @Item
              AND [ETag] = @Version;

            IF @CargaArchivoID IS NOT NULL AND @HashExistente <> CONVERT(char(64), @Hash)
                THROW 50819, 'La misma version de SharePoint tiene un hash distinto.', 1;
        END;

        IF @CargaArchivoID IS NULL
            SELECT @CargaArchivoID = [CargaArchivoID],
                   @HojaExistente = [NombreHoja],
                   @Estado = [Estado],
                   @TotalFilas = [TotalFilas]
            FROM [contabilidad].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
            WHERE [ClienteID] = @ClienteID
              AND [FuenteContable] = @Fuente
              AND [HashArchivoSha256] = CONVERT(char(64), @Hash);

        IF @CargaArchivoID IS NOT NULL AND @HojaExistente <> @Hoja
            THROW 50820, 'El mismo archivo ya se registro con otra hoja.', 1;

        IF @CargaArchivoID IS NULL
        BEGIN
            INSERT INTO [contabilidad].[CargaArchivo]
            (
                [ClienteID], [FuenteContable], [NombreArchivo], [NombreHoja],
                [SharePointItemID], [SharePointUrl], [ETag], [CargadoPor],
                [BlobUri], [TamanoBytes], [HashArchivoSha256]
            )
            VALUES
            (
                @ClienteID, @Fuente, @Nombre, @Hoja,
                @Item, NULLIF(LTRIM(RTRIM(@SharePointUrl)), N''), @Version,
                NULLIF(LTRIM(RTRIM(@CargadoPor)), N''),
                @Uri, @TamanoBytes, CONVERT(char(64), @Hash)
            );
            SET @CargaArchivoID = CONVERT(bigint, SCOPE_IDENTITY());
            SET @Estado = 'RECIBIDA';
            SET @Resultado = 'NUEVA_CARGA';
            SET @DebeProcesar = 1;
        END
        ELSE
        BEGIN
            IF @Estado = 'PARCIAL'
            BEGIN
                SELECT @FilasRegistradas = COUNT(*)
                FROM [contabilidad].[CargaMovimiento]
                WHERE [CargaArchivoID] = @CargaArchivoID;
            END;

            IF @Estado = 'ERROR'
               OR (@Estado = 'PARCIAL' AND @TotalFilas > @FilasRegistradas)
            BEGIN
                UPDATE [contabilidad].[CargaArchivo]
                SET [Estado] = 'RECIBIDA',
                    [FechaInicioUTC] = SYSUTCDATETIME(),
                    [FechaFinUTC] = NULL,
                    [TotalFilas] = NULL,
                    [FilasNuevas] = NULL,
                    [FilasDuplicadas] = NULL,
                    [FilasConflicto] = NULL,
                    [FilasRechazadas] = NULL,
                    [Mensaje] = N'Reintento de la misma carga.'
                WHERE [CargaArchivoID] = @CargaArchivoID;
                SET @Estado = 'RECIBIDA';
                SET @Resultado = 'REINTENTO';
                SET @DebeProcesar = 1;
            END
            ELSE
            BEGIN
                SET @Resultado = 'ARCHIVO_EXISTENTE';
                SET @DebeProcesar = CASE WHEN @Estado = 'RECIBIDA' THEN 1 ELSE 0 END;
            END;
        END;

        COMMIT TRANSACTION;

        SELECT @CargaArchivoID AS [CargaArchivoID],
               @Estado AS [Estado], @Resultado AS [Resultado],
               @DebeProcesar AS [DebeProcesar];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
