-- Registra el top 3 de un modelo para una factura Invoice vigente.
-- Ejecutar este CREATE OR ALTER en un lote propio, despues de la migracion 006.
-- No cambia predicciones existentes ni decisiones de revision.
CREATE OR ALTER PROCEDURE [ml].[sp_RegistrarPrediccionPlantilla]
    @ClienteID bigint,
    @DocumentoXmlID bigint,
    @VersionExtractor smallint,
    @DatasetVersionID bigint,
    @NombreModelo nvarchar(200),
    @ModeloArtefactoSha256 varchar(128),
    @ManifiestoSha256 varchar(128),
    @HashVariablesSha256 varchar(128),
    @PlantillaTop1 nvarchar(max),
    @ProbabilidadTop1 decimal(18,12),
    @PlantillaTop2 nvarchar(max),
    @ProbabilidadTop2 decimal(18,12),
    @PlantillaTop3 nvarchar(max),
    @ProbabilidadTop3 decimal(18,12)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Nombre nvarchar(200) = NULLIF(LTRIM(RTRIM(@NombreModelo)), N'');
    DECLARE @HashModelo varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@ModeloArtefactoSha256)), ''));
    DECLARE @HashManifiesto varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@ManifiestoSha256)), ''));
    DECLARE @HashVariables varchar(128) = LOWER(NULLIF(LTRIM(RTRIM(@HashVariablesSha256)), ''));
    DECLARE @P1 decimal(9,8);
    DECLARE @P2 decimal(9,8);
    DECLARE @P3 decimal(9,8);
    -- Las probabilidades de AutoGluon pueden variar unas unidades en la
    -- octava cifra decimal entre ejecuciones del mismo artefacto. Solo se
    -- tolera esa variacion si modelo, variables y las tres plantillas son iguales.
    DECLARE @ToleranciaProbabilidad decimal(18,12) = 0.000001000000;
    DECLARE @ClienteModelo bigint;
    DECLARE @PrediccionPlantillaID bigint;
    DECLARE @LockResult int;
    DECLARE @LockResource nvarchar(255);

    IF @ClienteID IS NULL OR @ClienteID <= 0
       OR @DocumentoXmlID IS NULL OR @DocumentoXmlID <= 0
       OR @VersionExtractor IS NULL OR @VersionExtractor <> 1
       OR @DatasetVersionID IS NULL OR @DatasetVersionID <= 0
        THROW 50910, 'Identificadores o version del extractor no validos.', 1;

    IF @Nombre IS NULL OR LEN(@Nombre) > 120
        THROW 50911, 'NombreModelo es obligatorio y no puede superar 120 caracteres.', 1;

    IF @HashModelo IS NULL OR LEN(@HashModelo) <> 64
       OR @HashModelo COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
       OR @HashManifiesto IS NULL OR LEN(@HashManifiesto) <> 64
       OR @HashManifiesto COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
       OR @HashVariables IS NULL OR LEN(@HashVariables) <> 64
       OR @HashVariables COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
        THROW 50912, 'Los tres hash deben ser SHA-256 hexadecimales.', 1;

    IF NULLIF(LTRIM(RTRIM(@PlantillaTop1)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@PlantillaTop2)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@PlantillaTop3)), N'') IS NULL
       OR @PlantillaTop1 COLLATE Latin1_General_100_BIN2 = @PlantillaTop2 COLLATE Latin1_General_100_BIN2
       OR @PlantillaTop1 COLLATE Latin1_General_100_BIN2 = @PlantillaTop3 COLLATE Latin1_General_100_BIN2
       OR @PlantillaTop2 COLLATE Latin1_General_100_BIN2 = @PlantillaTop3 COLLATE Latin1_General_100_BIN2
        THROW 50913, 'Se requieren tres plantillas distintas y no vacias.', 1;

    IF @ProbabilidadTop1 IS NULL OR @ProbabilidadTop1 NOT BETWEEN 0 AND 1
       OR @ProbabilidadTop2 IS NULL OR @ProbabilidadTop2 NOT BETWEEN 0 AND @ProbabilidadTop1
       OR @ProbabilidadTop3 IS NULL OR @ProbabilidadTop3 NOT BETWEEN 0 AND @ProbabilidadTop2
        THROW 50914, 'Las probabilidades deben estar entre 0 y 1, en orden descendente.', 1;

    SET @P1 = CONVERT(decimal(9,8), @ProbabilidadTop1);
    SET @P2 = CONVERT(decimal(9,8), @ProbabilidadTop2);
    SET @P3 = CONVERT(decimal(9,8), @ProbabilidadTop3);

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource = CONCAT(N'ml:prediccion:', @DocumentoXmlID, N':', @HashModelo);
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50915, 'No se pudo bloquear la prediccion.', 1;

        SELECT @ClienteModelo = [ClienteID]
        FROM [ml].[DatasetVersion]
        WHERE [DatasetVersionID] = @DatasetVersionID;

        IF @ClienteModelo IS NULL OR @ClienteModelo <> @ClienteID
            THROW 50916, 'El dataset del modelo no corresponde al cliente.', 1;

        SELECT @PrediccionPlantillaID = [PrediccionPlantillaID]
        FROM [ml].[PrediccionPlantilla] WITH (UPDLOCK, HOLDLOCK)
        WHERE [DocumentoXmlID] = @DocumentoXmlID
          AND [ModeloArtefactoSha256] = CONVERT(char(64), @HashModelo);

        IF @PrediccionPlantillaID IS NOT NULL
        BEGIN
            IF NOT EXISTS
            (
                SELECT 1
                FROM [ml].[PrediccionPlantilla]
                WHERE [PrediccionPlantillaID] = @PrediccionPlantillaID
                  AND [VersionExtractor] = @VersionExtractor
                  AND [DatasetVersionID] = @DatasetVersionID
                  AND [NombreModelo] COLLATE Latin1_General_100_BIN2 = @Nombre COLLATE Latin1_General_100_BIN2
                  AND [ManifiestoSha256] = CONVERT(char(64), @HashManifiesto)
                  AND [HashVariablesSha256] = CONVERT(char(64), @HashVariables)
                  AND DATALENGTH([PlantillaTop1]) = DATALENGTH(@PlantillaTop1)
                  AND [PlantillaTop1] COLLATE Latin1_General_100_BIN2 = @PlantillaTop1 COLLATE Latin1_General_100_BIN2
                  AND ABS(CONVERT(decimal(18,12), [ProbabilidadTop1]) - @ProbabilidadTop1)
                      <= @ToleranciaProbabilidad
                  AND DATALENGTH([PlantillaTop2]) = DATALENGTH(@PlantillaTop2)
                  AND [PlantillaTop2] COLLATE Latin1_General_100_BIN2 = @PlantillaTop2 COLLATE Latin1_General_100_BIN2
                  AND ABS(CONVERT(decimal(18,12), [ProbabilidadTop2]) - @ProbabilidadTop2)
                      <= @ToleranciaProbabilidad
                  AND DATALENGTH([PlantillaTop3]) = DATALENGTH(@PlantillaTop3)
                  AND [PlantillaTop3] COLLATE Latin1_General_100_BIN2 = @PlantillaTop3 COLLATE Latin1_General_100_BIN2
                  AND ABS(CONVERT(decimal(18,12), [ProbabilidadTop3]) - @ProbabilidadTop3)
                      <= @ToleranciaProbabilidad
            )
                THROW 50917, 'Ya existe una prediccion del mismo modelo con contenido distinto.', 1;

            COMMIT TRANSACTION;

            SELECT [PrediccionPlantillaID], [DocumentoXmlID], [DatasetVersionID],
                   [EstadoRevision], [FechaPrediccionUTC],
                   'YA_EXISTE' AS [Resultado]
            FROM [ml].[PrediccionPlantilla]
            WHERE [PrediccionPlantillaID] = @PrediccionPlantillaID;
            RETURN;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM [ml].[vw_FacturaOrigenMlV1]
            WHERE [ClienteID] = @ClienteID
              AND [DocumentoXmlID] = @DocumentoXmlID
              AND [VersionExtractor] = @VersionExtractor
        )
            THROW 50918, 'El XML no es una factura Invoice vigente y procesada del cliente.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM [ml].[DatasetFila]
            WHERE [DatasetVersionID] = @DatasetVersionID
              AND [DocumentoXmlID] = @DocumentoXmlID
        )
            THROW 50919, 'El XML pertenece al dataset de entrenamiento; no se registra inferencia.', 1;

        -- DatasetFila guarda solo etiquetas aceptadas. La fuente del snapshot
        -- incluyo tambien facturas historicas sin match aceptado.
        IF EXISTS
        (
            SELECT 1
            FROM [dian].[XmlExtraccion] AS e
            JOIN [ml].[DatasetVersion] AS d
              ON d.[DatasetVersionID] = @DatasetVersionID
            WHERE e.[DocumentoXmlID] = @DocumentoXmlID
              AND e.[VersionExtractor] = @VersionExtractor
              AND e.[FechaExtraccionUTC] <= d.[FechaCreacionUTC]
        )
            THROW 50920, 'El XML pertenece a la poblacion historica del snapshot; no se registra inferencia.', 1;

        INSERT INTO [ml].[PrediccionPlantilla]
        (
            [DocumentoXmlID], [VersionExtractor], [DatasetVersionID], [NombreModelo],
            [ModeloArtefactoSha256], [ManifiestoSha256], [HashVariablesSha256],
            [PlantillaTop1], [ProbabilidadTop1], [PlantillaTop2], [ProbabilidadTop2],
            [PlantillaTop3], [ProbabilidadTop3]
        )
        VALUES
        (
            @DocumentoXmlID, @VersionExtractor, @DatasetVersionID, CONVERT(nvarchar(120), @Nombre),
            CONVERT(char(64), @HashModelo), CONVERT(char(64), @HashManifiesto),
            CONVERT(char(64), @HashVariables),
            @PlantillaTop1, @P1, @PlantillaTop2, @P2, @PlantillaTop3, @P3
        );

        SET @PrediccionPlantillaID = SCOPE_IDENTITY();
        COMMIT TRANSACTION;

        SELECT [PrediccionPlantillaID], [DocumentoXmlID], [DatasetVersionID],
               [EstadoRevision], [FechaPrediccionUTC],
               'REGISTRADA' AS [Resultado]
        FROM [ml].[PrediccionPlantilla]
        WHERE [PrediccionPlantillaID] = @PrediccionPlantillaID;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
