-- Predicciones de plantillas contables (sin ratios ni valores por cuenta).
-- Ejecutar una sola vez en la base dev, despues de 003_xml_extraction.sql y
-- 005_ml_dataset.sql. Compatible con el editor web de Azure SQL (sin GO).
-- No inserta predicciones ni concede permisos directos sobre la tabla.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50900, 'Base de datos inesperada para predicciones ML.', 1;

IF SCHEMA_ID(N'ml') IS NULL
   OR OBJECT_ID(N'ml.DatasetVersion', N'U') IS NULL
   OR OBJECT_ID(N'dian.XmlExtraccion', N'U') IS NULL
    THROW 50901, 'Faltan objetos del dataset ML o de extraccion XML.', 1;

IF OBJECT_ID(N'ml.PrediccionPlantilla', N'U') IS NOT NULL
    THROW 50902, 'ml.PrediccionPlantilla ya existe; no se modifico nada.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    CREATE TABLE [ml].[PrediccionPlantilla]
    (
        [PrediccionPlantillaID] bigint IDENTITY(1,1) NOT NULL,
        [DocumentoXmlID] bigint NOT NULL,
        [VersionExtractor] smallint NOT NULL,
        [DatasetVersionID] bigint NOT NULL,
        [NombreModelo] nvarchar(120) NOT NULL,
        [ModeloArtefactoSha256] char(64) NOT NULL,
        [ManifiestoSha256] char(64) NOT NULL,
        [HashVariablesSha256] char(64) NOT NULL,
        [PlantillaTop1] nvarchar(max) NOT NULL,
        [ProbabilidadTop1] decimal(9,8) NOT NULL,
        [PlantillaTop2] nvarchar(max) NOT NULL,
        [ProbabilidadTop2] decimal(9,8) NOT NULL,
        [PlantillaTop3] nvarchar(max) NOT NULL,
        [ProbabilidadTop3] decimal(9,8) NOT NULL,
        [EstadoRevision] varchar(20)
            CONSTRAINT [DF_MlPrediccionPlantilla_Estado] DEFAULT ('PENDIENTE') NOT NULL,
        [OpcionSeleccionada] tinyint NULL,
        [PlantillaCorregida] nvarchar(max) NULL,
        [EtiquetasRevisionJson] nvarchar(max) NULL,
        [ComentarioRevision] nvarchar(1000) NULL,
        [RevisadoPor] nvarchar(256) NULL,
        [FechaRevisionUTC] datetime2(3) NULL,
        [FechaPrediccionUTC] datetime2(3)
            CONSTRAINT [DF_MlPrediccionPlantilla_FechaPrediccion] DEFAULT (SYSUTCDATETIME()) NOT NULL,
        [FechaActualizacionUTC] datetime2(3)
            CONSTRAINT [DF_MlPrediccionPlantilla_FechaActualizacion] DEFAULT (SYSUTCDATETIME()) NOT NULL,
        [RowVersion] rowversion NOT NULL,

        CONSTRAINT [PK_MlPrediccionPlantilla]
            PRIMARY KEY CLUSTERED ([PrediccionPlantillaID]),
        CONSTRAINT [FK_MlPrediccionPlantilla_Extraccion]
            FOREIGN KEY ([DocumentoXmlID], [VersionExtractor])
            REFERENCES [dian].[XmlExtraccion] ([DocumentoXmlID], [VersionExtractor]),
        CONSTRAINT [FK_MlPrediccionPlantilla_Dataset]
            FOREIGN KEY ([DatasetVersionID])
            REFERENCES [ml].[DatasetVersion] ([DatasetVersionID]),
        CONSTRAINT [CK_MlPrediccionPlantilla_Extractor]
            CHECK ([VersionExtractor] = 1),
        CONSTRAINT [CK_MlPrediccionPlantilla_Nombre]
            CHECK (NULLIF(LTRIM(RTRIM([NombreModelo])), N'') IS NOT NULL),
        CONSTRAINT [CK_MlPrediccionPlantilla_Hashes]
            CHECK
            (
                LEN([ModeloArtefactoSha256]) = 64 AND
                [ModeloArtefactoSha256] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%' AND
                LEN([ManifiestoSha256]) = 64 AND
                [ManifiestoSha256] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%' AND
                LEN([HashVariablesSha256]) = 64 AND
                [HashVariablesSha256] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'
            ),
        CONSTRAINT [CK_MlPrediccionPlantilla_Opciones]
            CHECK
            (
                NULLIF(LTRIM(RTRIM([PlantillaTop1])), N'') IS NOT NULL AND
                NULLIF(LTRIM(RTRIM([PlantillaTop2])), N'') IS NOT NULL AND
                NULLIF(LTRIM(RTRIM([PlantillaTop3])), N'') IS NOT NULL AND
                [PlantillaTop1] COLLATE Latin1_General_100_BIN2 <>
                    [PlantillaTop2] COLLATE Latin1_General_100_BIN2 AND
                [PlantillaTop1] COLLATE Latin1_General_100_BIN2 <>
                    [PlantillaTop3] COLLATE Latin1_General_100_BIN2 AND
                [PlantillaTop2] COLLATE Latin1_General_100_BIN2 <>
                    [PlantillaTop3] COLLATE Latin1_General_100_BIN2
            ),
        CONSTRAINT [CK_MlPrediccionPlantilla_Probabilidades]
            CHECK
            (
                [ProbabilidadTop1] BETWEEN 0 AND 1 AND
                [ProbabilidadTop2] BETWEEN 0 AND [ProbabilidadTop1] AND
                [ProbabilidadTop3] BETWEEN 0 AND [ProbabilidadTop2]
            ),
        CONSTRAINT [CK_MlPrediccionPlantilla_Etiquetas]
            CHECK
            (
                [EtiquetasRevisionJson] IS NULL OR
                (ISJSON([EtiquetasRevisionJson]) = 1 AND
                 LEFT(LTRIM([EtiquetasRevisionJson]), 1) = N'[')
            ),
        CONSTRAINT [CK_MlPrediccionPlantilla_Revision]
            CHECK
            (
                ([EstadoRevision] = 'PENDIENTE' AND [OpcionSeleccionada] IS NULL AND
                 [PlantillaCorregida] IS NULL AND [RevisadoPor] IS NULL AND
                 [FechaRevisionUTC] IS NULL)
                OR
                ([EstadoRevision] = 'APROBADA' AND [OpcionSeleccionada] IS NOT NULL AND
                 [OpcionSeleccionada] BETWEEN 1 AND 3 AND
                 [PlantillaCorregida] IS NULL AND
                 NULLIF(LTRIM(RTRIM([RevisadoPor])), N'') IS NOT NULL AND
                 [FechaRevisionUTC] IS NOT NULL)
                OR
                ([EstadoRevision] = 'CORREGIDA' AND [OpcionSeleccionada] IS NULL AND
                 NULLIF(LTRIM(RTRIM([PlantillaCorregida])), N'') IS NOT NULL AND
                 NULLIF(LTRIM(RTRIM([RevisadoPor])), N'') IS NOT NULL AND
                 [FechaRevisionUTC] IS NOT NULL)
                OR
                ([EstadoRevision] = 'RECHAZADA' AND [OpcionSeleccionada] IS NULL AND
                 [PlantillaCorregida] IS NULL AND
                 NULLIF(LTRIM(RTRIM([RevisadoPor])), N'') IS NOT NULL AND
                 [FechaRevisionUTC] IS NOT NULL)
            )
    );

    -- La identidad del artefacto permite recalcular con otro modelo sin
    -- duplicar la misma prediccion en reintentos del mismo modelo.
    CREATE UNIQUE INDEX [UX_MlPrediccionPlantilla_XmlModelo]
        ON [ml].[PrediccionPlantilla] ([DocumentoXmlID], [ModeloArtefactoSha256]);

    CREATE INDEX [IX_MlPrediccionPlantilla_Revision]
        ON [ml].[PrediccionPlantilla]
            ([EstadoRevision], [FechaPrediccionUTC], [PrediccionPlantillaID])
        INCLUDE ([DocumentoXmlID], [DatasetVersionID], [ProbabilidadTop1]);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT DB_NAME() AS [BaseActual],
       OBJECT_ID(N'ml.PrediccionPlantilla', N'U') AS [PrediccionPlantillaObjectID];
