CREATE OR ALTER PROCEDURE [contabilidad].[sp_RegistrarMovimientoContable]
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
    DECLARE @NomCiudad nvarchar(4000);
    DECLARE @CC nvarchar(4000);

    IF @CargaArchivoID IS NULL OR @CargaArchivoID <= 0
       OR @FilaOrigen IS NULL OR @FilaOrigen < 2
        THROW 50830, 'CargaArchivoID y FilaOrigen deben ser validos.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @ClienteID = [ClienteID],
               @Fuente = [FuenteContable],
               @Estado = [Estado]
        FROM [contabilidad].[CargaArchivo] WITH (UPDLOCK, HOLDLOCK)
        WHERE [CargaArchivoID] = @CargaArchivoID;

        IF @ClienteID IS NULL
            THROW 50831, 'La carga contable no existe.', 1;

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

        IF @Estado NOT IN ('RECIBIDA', 'PROCESANDO')
            THROW 50832, 'La carga no admite nuevas filas.', 1;

        IF COALESCE(ISJSON(@FilaJson), 0) <> 1
            SET @Error = N'FilaJson no es JSON valido.';
        ELSE IF EXISTS
        (
            SELECT 1 FROM OPENJSON(@FilaJson)
            WHERE [type] IN (4, 5) OR DATALENGTH([value]) > 8000
        )
            SET @Error = N'FilaJson contiene estructuras o columnas demasiado largas.';
        ELSE
        BEGIN
            SELECT
                @FechaTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Fecha'))), N''),
                @Documento = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Documento'))), N''),
                @TipoDoc = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.TipoDoc'))), N''),
                @NumDoc = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.NumDoc'))), N''),
                @Cuenta = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Cuenta'))), N''),
                @NomCuenta = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.NomCuenta'))), N''),
                @Concepto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Concepto'))), N''),
                @Naturaleza = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Naturaleza'))), N'')),
                @Centro = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Centro'))), N''),
                @CodigoCtaBancaria = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.CodigoCtaBancaria'))), N''),
                @CodigoUsuario = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.CodigoUsuario'))), N''),
                @DebitoTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Debito'))), N''),
                @CreditoTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Credito'))), N''),
                @IdentidadTercero = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.IdentidadTercero'))), N''),
                @DocFuente = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.DocFuente'))), N''),
                @FechaSistemaTexto = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.FechaSistema'))), N''),
                @Ind = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.IndContabilidad'))), N''),
                @Dv = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Dv'))), N''),
                @NombreTercero = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.NombreTercero'))), N''),
                @CuentaBancaria = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.CuentaBancaria'))), N''),
                @NomCentro = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.NomCentro'))), N''),
                @DescripcionCorta = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.DescripcionCorta'))), N''),
                @Direccion = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Direccion'))), N''),
                @Telefonos = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.Telefonos'))), N''),
                @NumeroMovil = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.NumeroMovil'))), N''),
                @NomCiudad = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.NomCiudad'))), N''),
                @CC = NULLIF(LTRIM(RTRIM(JSON_VALUE(@FilaJson, '$.CC'))), N'');

            SET @Fecha = TRY_CONVERT(date, REPLACE(@FechaTexto, N'/', N'-'), 23);
            SET @FechaSistema = TRY_CONVERT(datetime2(3), @FechaSistemaTexto, 126);
            SET @Debito = TRY_CONVERT(decimal(19,4), @DebitoTexto);
            SET @Credito = TRY_CONVERT(decimal(19,4), @CreditoTexto);

            SET @Error = CASE
                WHEN @Ind IS NULL OR LEN(@Ind) > 100 THEN N'IndContabilidad obligatorio o demasiado largo.'
                WHEN @Fecha IS NULL THEN N'Fecha invalida; use aaaa-mm-dd.'
                WHEN @Documento IS NULL OR LEN(@Documento) > 100 THEN N'Documento obligatorio o demasiado largo.'
                WHEN @TipoDoc IS NULL OR LEN(@TipoDoc) > 50 THEN N'TipoDoc obligatorio o demasiado largo.'
                WHEN @NumDoc IS NULL OR LEN(@NumDoc) > 100 THEN N'NumDoc obligatorio o demasiado largo.'
                WHEN @Cuenta IS NULL OR LEN(@Cuenta) > 50 THEN N'Cuenta obligatoria o demasiado larga.'
                WHEN @Naturaleza IS NULL OR @Naturaleza NOT IN (N'D', N'C') THEN N'Naturaleza debe ser D o C.'
                WHEN @Debito IS NULL OR @Credito IS NULL THEN N'Debito y Credito deben ser decimales.'
                WHEN TRY_CONVERT(decimal(38,10), @DebitoTexto) <> @Debito
                  OR TRY_CONVERT(decimal(38,10), @CreditoTexto) <> @Credito
                    THEN N'Debito o Credito tienen mas de 4 decimales significativos.'
                WHEN @IdentidadTercero IS NULL OR LEN(@IdentidadTercero) > 100 THEN N'IdentidadTercero obligatorio o demasiado largo.'
                WHEN @FechaSistemaTexto IS NOT NULL AND @FechaSistema IS NULL THEN N'FechaSistema invalida.'
                WHEN LEN(@NomCuenta) > 300 OR LEN(@NombreTercero) > 300
                  OR LEN(@NomCentro) > 300 THEN N'Nombre demasiado largo.'
                WHEN LEN(@Concepto) > 2000 THEN N'Concepto demasiado largo.'
                WHEN LEN(@Centro) > 100 OR LEN(@CodigoCtaBancaria) > 100
                  OR LEN(@CodigoUsuario) > 100 OR LEN(@DocFuente) > 100
                  OR LEN(@CuentaBancaria) > 100 OR LEN(@NumeroMovil) > 100
                  OR LEN(@CC) > 100 THEN N'Codigo o identificador demasiado largo.'
                WHEN LEN(@Dv) > 20 THEN N'Dv demasiado largo.'
                WHEN LEN(@DescripcionCorta) > 1000 THEN N'DescripcionCorta demasiado larga.'
                WHEN LEN(@Direccion) > 500 THEN N'Direccion demasiado larga.'
                WHEN LEN(@Telefonos) > 200 OR LEN(@NomCiudad) > 200
                    THEN N'Telefonos o NomCiudad demasiado largo.'
                ELSE NULL
            END;
        END;

        IF @Error IS NOT NULL
        BEGIN
            SET @Resultado = 'RECHAZADO';
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
                HASHBYTES('SHA2_256', CONVERT(varbinary(max), @Canonico)), 2));

            SET @LockResource = CONCAT(N'contabilidad:mov:', @ClienteID,
                                       N':', @Fuente, N':', UPPER(@Ind));
            EXEC @LockResult = sys.sp_getapplock
                @Resource = @LockResource,
                @LockMode = 'Exclusive',
                @LockOwner = 'Transaction',
                @LockTimeout = 10000;
            IF @LockResult < 0
                THROW 50833, 'No fue posible bloquear el movimiento.', 1;

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
                    @CodigoCtaBancaria, @CodigoUsuario, @Debito, @Credito,
                    @IdentidadTercero, @DocFuente, @FechaSistema, @Dv,
                    @NombreTercero, @CuentaBancaria, @NomCentro,
                    @DescripcionCorta, @Direccion, @Telefonos,
                    @NumeroMovil, @NomCiudad, @CC
                );
                SET @MovimientoID = CONVERT(bigint, SCOPE_IDENTITY());
                SET @Resultado = 'NUEVO';
            END
            ELSE IF @HashExistente = CONVERT(char(64), @Hash)
                SET @Resultado = 'DUPLICADO';
            ELSE
            BEGIN
                SET @Resultado = 'ID_CON_CONTENIDO_DISTINTO';
                SET @Detalle = N'Se conserva la primera version del movimiento.';
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

        IF @Estado = 'RECIBIDA'
            UPDATE [contabilidad].[CargaArchivo]
            SET [Estado] = 'PROCESANDO'
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
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
