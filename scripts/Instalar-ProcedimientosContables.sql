-- Instalacion de los tres procedimientos contables en una sola ejecucion.
-- Requiere sql/migrations/004_contabilidad_historica.sql ya instalado.
-- No crea tablas, no elimina datos y puede volver a ejecutarse.
-- Generado por scripts/Generar-InstalacionProcedimientosContables.py.
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50880, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;
IF OBJECT_ID(N'contabilidad.CargaArchivo', N'U') IS NULL
   OR OBJECT_ID(N'contabilidad.MovimientoHistorico', N'U') IS NULL
   OR OBJECT_ID(N'contabilidad.CargaMovimiento', N'U') IS NULL
    THROW 50881, 'Faltan las tablas de la migracion contable 004; no se modifico nada.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals
               WHERE [name] = N'dian_runtime' AND [type] = 'R')
    THROW 50882, 'Falta el rol dian_runtime; no se modifico nada.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Definicion nvarchar(max);
    DECLARE @Paso nvarchar(128) = N'inicio';

    -- Fuente: sql/procedures/sp_IniciarCargaContable.sql
    SET @Paso = N'sp_IniciarCargaContable';
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [contabilidad].[sp_IniciarCargaContable]
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

    DECLARE @Fuente nvarchar(200) = UPPER(NULLIF(LTRIM(RTRIM(@FuenteContable)), N''''));
    DECLARE @Nombre nvarchar(500) = NULLIF(LTRIM(RTRIM(@NombreArchivo)), N'''');
    DECLARE @Hoja nvarchar(256) = NULLIF(LTRIM(RTRIM(@NombreHoja)), N'''');
    DECLARE @Uri nvarchar(2000) = NULLIF(LTRIM(RTRIM(@BlobUri)), N'''');
    DECLARE @Hash varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashArchivoSha256)), ''''));
    DECLARE @Item nvarchar(300) = NULLIF(LTRIM(RTRIM(@SharePointItemID)), N'''');
    DECLARE @Version nvarchar(400) = NULLIF(LTRIM(RTRIM(@ETag)), N'''');
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
        THROW 50810, ''ClienteID debe ser positivo.'', 1;
    IF @Fuente IS NULL OR LEN(@Fuente) > 80
        THROW 50811, ''FuenteContable es obligatoria y admite hasta 80 caracteres.'', 1;
    IF @Nombre IS NULL OR LEN(@Nombre) > 260
       OR @Hoja IS NULL OR LEN(@Hoja) > 128
        THROW 50812, ''NombreArchivo o NombreHoja no valido.'', 1;
' AS nvarchar(max))
        + N'    IF @Uri IS NULL OR LEN(@Uri) > 1000 OR CHARINDEX(N''?'', @Uri) > 0
        THROW 50813, ''BlobUri no valida; no incluya SAS ni parametros.'', 1;
    IF @TamanoBytes IS NULL OR @TamanoBytes <= 0
        THROW 50814, ''TamanoBytes debe ser positivo.'', 1;
    IF @Hash IS NULL OR LEN(@Hash) <> 64
       OR @Hash COLLATE Latin1_General_100_BIN2 LIKE ''%[^0-9a-f]%''
        THROW 50815, ''HashArchivoSha256 debe ser hexadecimal SHA-256.'', 1;
    IF LEN(@Item) > 150 OR LEN(@Version) > 200
       OR LEN(@SharePointUrl) > 1000 OR LEN(@CargadoPor) > 256
        THROW 50816, ''Metadatos de SharePoint demasiado largos.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS
        (
            SELECT 1 FROM [dian].[Cliente]
            WHERE [ClienteID] = @ClienteID AND [Estado] = ''ACTIVO''
        )
            THROW 50817, ''El cliente no existe o no esta activo.'', 1;

        SET @LockResource = CONCAT(N''contabilidad:carga:'', @ClienteID, N'':'', @Fuente);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 10000;
        IF @LockResult < 0
            THROW 50818, ''No fue posible bloquear la carga contable.'', 1;

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
'
        + N'              AND [ETag] = @Version;

            IF @CargaArchivoID IS NOT NULL AND @HashExistente <> CONVERT(char(64), @Hash)
                THROW 50819, ''La misma version de SharePoint tiene un hash distinto.'', 1;
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
            THROW 50820, ''El mismo archivo ya se registro con otra hoja.'', 1;

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
                @Item, NULLIF(LTRIM(RTRIM(@SharePointUrl)), N''''), @Version,
                NULLIF(LTRIM(RTRIM(@CargadoPor)), N''''),
                @Uri, @TamanoBytes, CONVERT(char(64), @Hash)
            );
            SET @CargaArchivoID = CONVERT(bigint, SCOPE_IDENTITY());
            SET @Estado = ''RECIBIDA'';
            SET @Resultado = ''NUEVA_CARGA'';
            SET @DebeProcesar = 1;
        END
        ELSE
        BEGIN
            IF @Estado = ''PARCIAL''
            BEGIN
                SELECT @FilasRegistradas = COUNT(*)
'
        + N'                FROM [contabilidad].[CargaMovimiento]
                WHERE [CargaArchivoID] = @CargaArchivoID;
            END;

            IF @Estado = ''ERROR''
               OR (@Estado = ''PARCIAL'' AND @TotalFilas > @FilasRegistradas)
            BEGIN
                UPDATE [contabilidad].[CargaArchivo]
                SET [Estado] = ''RECIBIDA'',
                    [FechaInicioUTC] = SYSUTCDATETIME(),
                    [FechaFinUTC] = NULL,
                    [TotalFilas] = NULL,
                    [FilasNuevas] = NULL,
                    [FilasDuplicadas] = NULL,
                    [FilasConflicto] = NULL,
                    [FilasRechazadas] = NULL,
                    [Mensaje] = N''Reintento de la misma carga.''
                WHERE [CargaArchivoID] = @CargaArchivoID;
                SET @Estado = ''RECIBIDA'';
                SET @Resultado = ''REINTENTO'';
                SET @DebeProcesar = 1;
            END
            ELSE
            BEGIN
                SET @Resultado = ''ARCHIVO_EXISTENTE'';
                SET @DebeProcesar = CASE WHEN @Estado = ''RECIBIDA'' THEN 1 ELSE 0 END;
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
END;';
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/procedures/sp_RegistrarMovimientoContable.sql
    SET @Paso = N'sp_RegistrarMovimientoContable';
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [contabilidad].[sp_RegistrarMovimientoContable]
    @CargaArchivoID bigint,
    @FilaOrigen int,
    @FilaJson nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClienteID bigint;
    DECLARE @Fuente nvarchar(80);
    DECLARE @Estado varchar(20);
    DECLARE @MovimientoID bigint;
    DECLARE @Resultado varchar(30);
    DECLARE @Detalle nvarchar(1000);
    DECLARE @SolicitudExistente bit = 0;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);
    DECLARE @Hash varchar(64);
    DECLARE @HashExistente char(64);
    DECLARE @Canonico nvarchar(max);
    DECLARE @Error nvarchar(1000);

    DECLARE @FechaTexto nvarchar(4000);
    DECLARE @Fecha date;
    DECLARE @Documento nvarchar(4000);
    DECLARE @TipoDoc nvarchar(4000);
    DECLARE @NumDoc nvarchar(4000);
    DECLARE @Cuenta nvarchar(4000);
    DECLARE @NomCuenta nvarchar(4000);
    DECLARE @Concepto nvarchar(4000);
    DECLARE @Naturaleza nvarchar(4000);
    DECLARE @Centro nvarchar(4000);
    DECLARE @CodigoCtaBancaria nvarchar(4000);
    DECLARE @CodigoUsuario nvarchar(4000);
    DECLARE @DebitoTexto nvarchar(4000);
    DECLARE @CreditoTexto nvarchar(4000);
    DECLARE @Debito decimal(19,4);
    DECLARE @Credito decimal(19,4);
    DECLARE @IdentidadTercero nvarchar(4000);
    DECLARE @DocFuente nvarchar(4000);
    DECLARE @FechaSistemaTexto nvarchar(4000);
    DECLARE @FechaSistema datetime2(3);
    DECLARE @Ind nvarchar(4000);
    DECLARE @Dv nvarchar(4000);
    DECLARE @NombreTercero nvarchar(4000);
    DECLARE @CuentaBancaria nvarchar(4000);
    DECLARE @NomCentro nvarchar(4000);
    DECLARE @DescripcionCorta nvarchar(4000);
    DECLARE @Direccion nvarchar(4000);
    DECLARE @Telefonos nvarchar(4000);
    DECLARE @NumeroMovil nvarchar(4000);
' AS nvarchar(max))
        + N'    DECLARE @NomCiudad nvarchar(4000);
    DECLARE @CC nvarchar(4000);

    IF @CargaArchivoID IS NULL OR @CargaArchivoID <= 0
       OR @FilaOrigen IS NULL OR @FilaOrigen < 2
        THROW 50830, ''CargaArchivoID y FilaOrigen deben ser validos.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @ClienteID = [ClienteID],
               @Fuente = [FuenteContable],
               @Estado = [Estado]
        FROM [contabilidad].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
        WHERE [CargaArchivoID] = @CargaArchivoID;

        IF @ClienteID IS NULL
            THROW 50831, ''La carga contable no existe.'', 1;

        SELECT @MovimientoID = [MovimientoID],
               @Resultado = [Resultado],
               @Detalle = [Detalle],
               @Hash = [HashContenidoSha256]
        FROM [contabilidad].[CargaMovimiento] WITH (UPDLOCK, HOLDLOCK)
        WHERE [CargaArchivoID] = @CargaArchivoID
          AND [FilaOrigen] = @FilaOrigen;

        IF @Resultado IS NOT NULL
        BEGIN
            SET @SolicitudExistente = 1;
            COMMIT TRANSACTION;
            SELECT @CargaArchivoID AS [CargaArchivoID],
                   @FilaOrigen AS [FilaOrigen],
                   @MovimientoID AS [MovimientoID],
                   @Resultado AS [Resultado],
                   @Hash AS [HashContenidoSha256],
                   @SolicitudExistente AS [SolicitudExistente],
                   @Detalle AS [Detalle];
            RETURN;
        END;

        IF @Estado NOT IN (''RECIBIDA'', ''PROCESANDO'')
            THROW 50832, ''La carga no admite nuevas filas.'', 1;

        IF COALESCE(ISJSON(@FilaJson), 0) <> 1
            SET @Error = N''FilaJson no es JSON valido.'';
        ELSE IF EXISTS
        (
            SELECT 1 FROM OPENJSON(@FilaJson)
'
        + N'            WHERE [type] IN (4, 5) OR DATALENGTH([value]) > 8000
        )
            SET @Error = N''FilaJson contiene estructuras o columnas demasiado largas.'';
        ELSE
        BEGIN
            SELECT
                @FechaTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Fecha''))), N''''),
                @Documento = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Documento''))), N''''),
                @TipoDoc = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.TipoDoc''))), N''''),
                @NumDoc = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.NumDoc''))), N''''),
                @Cuenta = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Cuenta''))), N''''),
                @NomCuenta = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.NomCuenta''))), N''''),
                @Concepto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Concepto''))), N''''),
                @Naturaleza = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Naturaleza''))), N'''')),
                @Centro = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Centro''))), N''''),
                @CodigoCtaBancaria = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.CodigoCtaBancaria''))), N''''),
                @CodigoUsuario = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.CodigoUsuario''))), N''''),
                @DebitoTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Debito''))), N''''),
                @CreditoTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Credito''))), N''''),
                @IdentidadTercero = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.IdentidadTercero''))), N''''),
                @DocFuente = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.DocFuente''))), N''''),
                @FechaSistemaTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.FechaSistema''))), N''''),
'
        + N'                @Ind = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.IndContabilidad''))), N''''),
                @Dv = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Dv''))), N''''),
                @NombreTercero = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.NombreTercero''))), N''''),
                @CuentaBancaria = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.CuentaBancaria''))), N''''),
                @NomCentro = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.NomCentro''))), N''''),
                @DescripcionCorta = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.DescripcionCorta''))), N''''),
                @Direccion = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Direccion''))), N''''),
                @Telefonos = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.Telefonos''))), N''''),
                @NumeroMovil = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.NumeroMovil''))), N''''),
                @NomCiudad = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.NomCiudad''))), N''''),
                @CC = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, ''$.CC''))), N'''');

            SET @Fecha = TRY_CONVERT(date, REPLACE(@FechaTexto, N''/'', N''-''), 23);
            SET @FechaSistema = TRY_CONVERT(datetime2(3), @FechaSistemaTexto, 126);
            SET @Debito = TRY_CONVERT(decimal(19,4), @DebitoTexto);
            SET @Credito = TRY_CONVERT(decimal(19,4), @CreditoTexto);

            SET @Error = CASE
                WHEN @Ind IS NULL OR LEN(@Ind) > 100 THEN N''IndContabilidad obligatorio o demasiado largo.''
                WHEN @Fecha IS NULL THEN N''Fecha invalida; use aaaa-mm-dd.''
                WHEN @Documento IS NULL OR LEN(@Documento) > 100 THEN N''Documento obligatorio o demasiado largo.''
                WHEN @TipoDoc IS NULL OR LEN(@TipoDoc) > 50 THEN N''TipoDoc obligatorio o demasiado largo.''
'
        + N'                WHEN @NumDoc IS NULL OR LEN(@NumDoc) > 100 THEN N''NumDoc obligatorio o demasiado largo.''
                WHEN @Cuenta IS NULL OR LEN(@Cuenta) > 50 THEN N''Cuenta obligatoria o demasiado larga.''
                WHEN @Naturaleza IS NULL OR @Naturaleza NOT IN (N''D'', N''C'') THEN N''Naturaleza debe ser D o C.''
                WHEN @Debito IS NULL OR @Credito IS NULL THEN N''Debito y Credito deben ser decimales.''
                WHEN TRY_CONVERT(decimal(38,10), @DebitoTexto) <> @Debito
                  OR TRY_CONVERT(decimal(38,10), @CreditoTexto) <> @Credito
                    THEN N''Debito o Credito tienen mas de 4 decimales significativos.''
                WHEN @IdentidadTercero IS NULL OR LEN(@IdentidadTercero) > 100 THEN N''IdentidadTercero obligatorio o demasiado largo.''
                WHEN @FechaSistemaTexto IS NOT NULL AND @FechaSistema IS NULL THEN N''FechaSistema invalida.''
                WHEN LEN(@NomCuenta) > 300 OR LEN(@NombreTercero) > 300
                  OR LEN(@NomCentro) > 300 THEN N''Nombre demasiado largo.''
                WHEN LEN(@Concepto) > 2000 THEN N''Concepto demasiado largo.''
                WHEN LEN(@Centro) > 100 OR LEN(@CodigoCtaBancaria) > 100
                  OR LEN(@CodigoUsuario) > 100 OR LEN(@DocFuente) > 100
                  OR LEN(@CuentaBancaria) > 100 OR LEN(@NumeroMovil) > 100
                  OR LEN(@CC) > 100 THEN N''Codigo o identificador demasiado largo.''
                WHEN LEN(@Dv) > 20 THEN N''Dv demasiado largo.''
                WHEN LEN(@DescripcionCorta) > 1000 THEN N''DescripcionCorta demasiado larga.''
                WHEN LEN(@Direccion) > 500 THEN N''Direccion demasiado larga.''
                WHEN LEN(@Telefonos) > 200 OR LEN(@NomCiudad) > 200
'
        + N'                    THEN N''Telefonos o NomCiudad demasiado largo.''
                ELSE NULL
            END;
        END;

        IF @Error IS NOT NULL
        BEGIN
            SET @Resultado = ''RECHAZADO'';
            SET @Detalle = @Error;
            INSERT INTO [contabilidad].[CargaMovimiento]
                ([CargaArchivoID], [FilaOrigen], [ClienteID], [FuenteContable],
                 [IndContabilidad], [Resultado], [Detalle])
            VALUES
                (@CargaArchivoID, @FilaOrigen, @ClienteID, @Fuente,
                 CASE WHEN LEN(@Ind) <= 100 THEN @Ind ELSE NULL END,
                 @Resultado, @Detalle);
        END
        ELSE
        BEGIN
            -- Contrato de hash v1: solo columnas contables; no incluye ID,
            -- orden de Excel, fecha de sistema ni datos de contacto.
            SELECT @Canonico =
            (
                SELECT CONVERT(char(10), @Fecha, 23) AS [Fecha],
                       @Documento AS [Documento], @TipoDoc AS [TipoDoc],
                       @NumDoc AS [NumDoc], @Cuenta AS [Cuenta],
                       @Concepto AS [Concepto], @Naturaleza AS [Naturaleza],
                       @Centro AS [Centro], @CC AS [CC],
                       CONVERT(varchar(40), @Debito) AS [Debito],
                       CONVERT(varchar(40), @Credito) AS [Credito],
                       @IdentidadTercero AS [IdentidadTercero],
                       @DocFuente AS [DocFuente]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
            );
            SET @Hash = LOWER(CONVERT(varchar(64),
                HASHBYTES(''SHA2_256'', CONVERT(varbinary(max), @Canonico)), 2));

            SET @LockResource = CONCAT(N''contabilidad:mov:'', @ClienteID,
'
        + N'                                       N'':'', @Fuente, N'':'', UPPER(@Ind));
            EXEC @LockResult = sys.sp_getapplock
                @Resource = @LockResource,
                @LockMode = ''Exclusive'',
                @LockOwner = ''Transaction'',
                @LockTimeout = 10000;
            IF @LockResult < 0
                THROW 50833, ''No fue posible bloquear el movimiento.'', 1;

            SELECT @MovimientoID = [MovimientoID],
                   @HashExistente = [HashContenidoSha256]
            FROM [contabilidad].[MovimientoHistorico] WITH (UPDLOCK, HOLDLOCK)
            WHERE [ClienteID] = @ClienteID
              AND [FuenteContable] = @Fuente
              AND [IndContabilidad] = @Ind;

            IF @MovimientoID IS NULL
            BEGIN
                INSERT INTO [contabilidad].[MovimientoHistorico]
                (
                    [ClienteID], [FuenteContable], [IndContabilidad],
                    [HashContenidoSha256], [CargaPrimeraID], [FilaPrimera],
                    [Fecha], [Documento], [TipoDoc], [NumDoc], [Cuenta],
                    [NomCuenta], [Concepto], [Naturaleza], [Centro],
                    [CodigoCtaBancaria], [CodigoUsuario], [Debito], [Credito],
                    [IdentidadTercero], [DocFuente], [FechaSistema], [Dv],
                    [NombreTercero], [CuentaBancaria], [NomCentro],
                    [DescripcionCorta], [Direccion], [Telefonos],
                    [NumeroMovil], [NomCiudad], [CC]
                )
                VALUES
                (
                    @ClienteID, @Fuente, @Ind,
                    CONVERT(char(64), @Hash), @CargaArchivoID, @FilaOrigen,
                    @Fecha, @Documento, @TipoDoc, @NumDoc, @Cuenta,
                    @NomCuenta, @Concepto, @Naturaleza, @Centro,
'
        + N'                    @CodigoCtaBancaria, @CodigoUsuario, @Debito, @Credito,
                    @IdentidadTercero, @DocFuente, @FechaSistema, @Dv,
                    @NombreTercero, @CuentaBancaria, @NomCentro,
                    @DescripcionCorta, @Direccion, @Telefonos,
                    @NumeroMovil, @NomCiudad, @CC
                );
                SET @MovimientoID = CONVERT(bigint, SCOPE_IDENTITY());
                SET @Resultado = ''NUEVO'';
            END
            ELSE IF @HashExistente = CONVERT(char(64), @Hash)
                SET @Resultado = ''DUPLICADO'';
            ELSE
            BEGIN
                SET @Resultado = ''ID_CON_CONTENIDO_DISTINTO'';
                SET @Detalle = N''Se conserva la primera version del movimiento.'';
            END;

            INSERT INTO [contabilidad].[CargaMovimiento]
                ([CargaArchivoID], [FilaOrigen], [ClienteID], [FuenteContable],
                 [IndContabilidad], [HashContenidoSha256], [MovimientoID],
                 [Resultado], [Detalle])
            VALUES
                (@CargaArchivoID, @FilaOrigen, @ClienteID, @Fuente,
                 @Ind, CONVERT(char(64), @Hash), @MovimientoID,
                 @Resultado, @Detalle);
        END;

        IF @Estado = ''RECIBIDA''
            UPDATE [contabilidad].[CargaArchivo]
            SET [Estado] = ''PROCESANDO''
            WHERE [CargaArchivoID] = @CargaArchivoID;

        COMMIT TRANSACTION;

        SELECT @CargaArchivoID AS [CargaArchivoID],
               @FilaOrigen AS [FilaOrigen],
               @MovimientoID AS [MovimientoID],
               @Resultado AS [Resultado],
               @Hash AS [HashContenidoSha256],
               @SolicitudExistente AS [SolicitudExistente],
               @Detalle AS [Detalle];
    END TRY
    BEGIN CATCH
'
        + N'        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;';
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/procedures/sp_FinalizarCargaContable.sql
    SET @Paso = N'sp_FinalizarCargaContable';
    SET @Definicion = CAST(N'CREATE OR ALTER PROCEDURE [contabilidad].[sp_FinalizarCargaContable]
    @CargaArchivoID bigint,
    @TotalFilasEsperadas int = NULL,
    @Mensaje nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado varchar(20);
    DECLARE @Resultado varchar(30);
    DECLARE @TotalFilas int;
    DECLARE @FilasProcesadas int;
    DECLARE @FilasPendientes int;
    DECLARE @FilasNuevas int;
    DECLARE @FilasDuplicadas int;
    DECLARE @FilasConflicto int;
    DECLARE @FilasRechazadas int;
    DECLARE @FechaMinima date;
    DECLARE @FechaMaxima date;
    DECLARE @MensajeFinal nvarchar(2000);

    IF @CargaArchivoID IS NULL OR @CargaArchivoID <= 0
        THROW 50850, ''CargaArchivoID debe ser positivo.'', 1;
    IF @TotalFilasEsperadas IS NOT NULL AND @TotalFilasEsperadas < 0
        THROW 50851, ''TotalFilasEsperadas no puede ser negativo.'', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Estado = [Estado],
               @TotalFilas = [TotalFilas],
               @FilasNuevas = [FilasNuevas],
               @FilasDuplicadas = [FilasDuplicadas],
               @FilasConflicto = [FilasConflicto],
               @FilasRechazadas = [FilasRechazadas],
               @FechaMinima = [FechaMinima],
               @FechaMaxima = [FechaMaxima],
               @MensajeFinal = [Mensaje]
        FROM [contabilidad].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
        WHERE [CargaArchivoID] = @CargaArchivoID;

        IF @Estado IS NULL
            THROW 50852, ''La carga contable no existe.'', 1;

        IF @Estado IN (''OK'', ''PARCIAL'', ''ERROR'')
        BEGIN
            SELECT @FilasProcesadas = COUNT(*)
            FROM [contabilidad].[CargaMovimiento]
            WHERE [CargaArchivoID] = @CargaArchivoID;
            SET @FilasPendientes = CASE
' AS nvarchar(max))
        + N'                WHEN COALESCE(@TotalFilas, @FilasProcesadas) > @FilasProcesadas
                    THEN COALESCE(@TotalFilas, @FilasProcesadas) - @FilasProcesadas
                ELSE 0
            END;
            SET @Resultado = ''YA_FINALIZADA'';
        END
        ELSE
        BEGIN
            SELECT @FilasProcesadas = COUNT(*),
                   @FilasNuevas = COALESCE(SUM(CASE WHEN [Resultado] = ''NUEVO'' THEN 1 ELSE 0 END), 0),
                   @FilasDuplicadas = COALESCE(SUM(CASE WHEN [Resultado] = ''DUPLICADO'' THEN 1 ELSE 0 END), 0),
                   @FilasConflicto = COALESCE(SUM(CASE WHEN [Resultado] = ''ID_CON_CONTENIDO_DISTINTO'' THEN 1 ELSE 0 END), 0),
                   @FilasRechazadas = COALESCE(SUM(CASE WHEN [Resultado] = ''RECHAZADO'' THEN 1 ELSE 0 END), 0)
            FROM [contabilidad].[CargaMovimiento]
            WHERE [CargaArchivoID] = @CargaArchivoID;

            SET @TotalFilas = COALESCE(@TotalFilasEsperadas, @FilasProcesadas);
            IF @TotalFilas < @FilasProcesadas
                THROW 50853, ''TotalFilasEsperadas es menor que las filas registradas.'', 1;
            SET @FilasPendientes = @TotalFilas - @FilasProcesadas;

            SELECT @FechaMinima = MIN(m.[Fecha]),
                   @FechaMaxima = MAX(m.[Fecha])
            FROM [contabilidad].[CargaMovimiento] AS cm
            JOIN [contabilidad].[MovimientoHistorico] AS m
              ON m.[MovimientoID] = cm.[MovimientoID]
            WHERE cm.[CargaArchivoID] = @CargaArchivoID
              AND cm.[Resultado] IN (''NUEVO'', ''DUPLICADO'');

            SET @Estado = CASE
                WHEN @TotalFilas = 0 OR @FilasProcesadas = 0 THEN ''ERROR''
                WHEN @FilasPendientes > 0 OR @FilasConflicto > 0
                     OR @FilasRechazadas > 0 THEN ''PARCIAL''
'
        + N'                ELSE ''OK''
            END;

            SET @MensajeFinal = COALESCE
            (
                NULLIF(LTRIM(RTRIM(@Mensaje)), N''''),
                CONCAT(N''Carga finalizada. Esperadas: '', @TotalFilas,
                       N''; procesadas: '', @FilasProcesadas,
                       N''; nuevas: '', @FilasNuevas,
                       N''; duplicadas: '', @FilasDuplicadas,
                       N''; conflictos: '', @FilasConflicto,
                       N''; rechazadas: '', @FilasRechazadas,
                       N''; pendientes: '', @FilasPendientes, N''.'')
            );

            UPDATE [contabilidad].[CargaArchivo]
            SET [Estado] = @Estado,
                [TotalFilas] = @TotalFilas,
                [FilasNuevas] = @FilasNuevas,
                [FilasDuplicadas] = @FilasDuplicadas,
                [FilasConflicto] = @FilasConflicto,
                [FilasRechazadas] = @FilasRechazadas,
                [FechaMinima] = @FechaMinima,
                [FechaMaxima] = @FechaMaxima,
                [Mensaje] = @MensajeFinal,
                [FechaFinUTC] = SYSUTCDATETIME()
            WHERE [CargaArchivoID] = @CargaArchivoID;
            SET @Resultado = ''FINALIZADA'';
        END;

        COMMIT TRANSACTION;

        SELECT @CargaArchivoID AS [CargaArchivoID],
               @Estado AS [Estado],
               @TotalFilas AS [TotalFilas],
               @FilasProcesadas AS [FilasProcesadas],
               @FilasPendientes AS [FilasPendientes],
               @FilasNuevas AS [FilasNuevas],
               @FilasDuplicadas AS [FilasDuplicadas],
               @FilasConflicto AS [FilasConflicto],
               @FilasRechazadas AS [FilasRechazadas],
               @FechaMinima AS [FechaMinima],
               @FechaMaxima AS [FechaMaxima],
'
        + N'               @Resultado AS [Resultado],
               @MensajeFinal AS [Mensaje];
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;';
    EXEC sys.sp_executesql @Definicion;

    -- Fuente: sql/security/contabilidad_runtime_grants.sql
    -- Ejecutar despues de instalar los tres procedimientos contables.
    -- El rol no recibe SELECT, INSERT ni UPDATE directos sobre tablas.
    IF NOT EXISTS
    (
        SELECT 1 FROM sys.database_principals
        WHERE [name] = N'dian_runtime' AND [type] = 'R'
    )
        THROW 50870, 'Falta el rol dian_runtime.', 1;
    
    IF OBJECT_ID(N'contabilidad.sp_IniciarCargaContable', N'P') IS NULL
       OR OBJECT_ID(N'contabilidad.sp_RegistrarMovimientoContable', N'P') IS NULL
       OR OBJECT_ID(N'contabilidad.sp_FinalizarCargaContable', N'P') IS NULL
        THROW 50871, 'Faltan procedimientos contables; no se concedieron permisos.', 1;
    
    GRANT EXECUTE ON OBJECT::[contabilidad].[sp_IniciarCargaContable] TO [dian_runtime];
    GRANT EXECUTE ON OBJECT::[contabilidad].[sp_RegistrarMovimientoContable] TO [dian_runtime];
    GRANT EXECUTE ON OBJECT::[contabilidad].[sp_FinalizarCargaContable] TO [dian_runtime];

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @DetalleError nvarchar(2048) = LEFT(CONCAT(
        N'Paso: ', @Paso, N'; error SQL ', ERROR_NUMBER(),
        N'; linea ', ERROR_LINE(), N': ', ERROR_MESSAGE()), 2048);
    THROW 50883, @DetalleError, 1;
END CATCH;

SELECT DB_NAME() AS [BaseActual],
       (SELECT COUNT(*) FROM sys.procedures
        WHERE [schema_id] = SCHEMA_ID(N'contabilidad')
          AND [name] IN (N'sp_IniciarCargaContable',
                         N'sp_RegistrarMovimientoContable',
                         N'sp_FinalizarCargaContable')) AS [ProcedimientosContables];
