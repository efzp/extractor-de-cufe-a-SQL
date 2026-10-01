SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[CargaArchivo]
(
    [CargaArchivoID] bigint IDENTITY(1,1) NOT NULL,
    [ClienteID] bigint NOT NULL,
    [CargaOriginalID] bigint NULL,
    [NombreArchivo] nvarchar(260) NOT NULL,
    [SharePointItemID] nvarchar(150) NULL,
    [SharePointUrl] nvarchar(1000) NULL,
    [ETag] nvarchar(200) NULL,
    [HashArchivoSha256] char(64) NULL,
    [NombreTablaOrigen] nvarchar(128) NULL,
    [CargadoPor] nvarchar(256) NULL,
    [FechaInicioUTC] datetime2(3) CONSTRAINT [DF_DianCargaArchivo_FechaInicio] DEFAULT (sysutcdatetime()) NOT NULL,
    [FechaFinUTC] datetime2(3) NULL,
    [Estado] varchar(30) CONSTRAINT [DF_DianCargaArchivo_Estado] DEFAULT ('RECIBIDA') NOT NULL,
    [TotalFilas] int NULL,
    [FilasValidas] int NULL,
    [FilasDuplicadas] int NULL,
    [FilasRevision] int NULL,
    [FilasError] int NULL,
    [Mensaje] nvarchar(2000) NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianCargaArchivo] PRIMARY KEY CLUSTERED ([CargaArchivoID]),
    CONSTRAINT [FK_DianCargaArchivo_Cliente] FOREIGN KEY ([ClienteID]) REFERENCES [dian].[Cliente] ([ClienteID]),
    CONSTRAINT [FK_DianCargaArchivo_Original] FOREIGN KEY ([CargaOriginalID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
    CONSTRAINT [CK_DianCargaArchivo_Estado] CHECK ([Estado] IN ('RECIBIDA', 'PROCESANDO', 'OK', 'PARCIAL', 'SIN_CAMBIOS', 'REQUIERE_REVISION', 'ERROR')),
    CONSTRAINT [CK_DianCargaArchivo_Conteos] CHECK
    (
        ([TotalFilas] IS NULL OR [TotalFilas] >= 0) AND
        ([FilasValidas] IS NULL OR [FilasValidas] >= 0) AND
        ([FilasDuplicadas] IS NULL OR [FilasDuplicadas] >= 0) AND
        ([FilasRevision] IS NULL OR [FilasRevision] >= 0) AND
        ([FilasError] IS NULL OR [FilasError] >= 0)
    )
);
GO

CREATE INDEX [IX_DianCargaArchivo_ClienteHash]
    ON [dian].[CargaArchivo] ([ClienteID], [HashArchivoSha256], [Estado]);
GO

CREATE UNIQUE INDEX [UX_DianCargaArchivo_SharePointVersion]
    ON [dian].[CargaArchivo] ([ClienteID], [SharePointItemID], [ETag])
    WHERE [SharePointItemID] IS NOT NULL
      AND [ETag] IS NOT NULL;
GO
