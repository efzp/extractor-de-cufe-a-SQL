SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[DocumentoProcesoHistorial]
(
    [ProcesoHistorialID] bigint IDENTITY(1,1) NOT NULL,
    [DocumentoID] bigint NOT NULL,
    [CargaArchivoID] bigint NULL,
    [EstadoAnterior] varchar(30) NULL,
    [EstadoNuevo] varchar(30) NOT NULL,
    [TipoEvento] varchar(40) NOT NULL,
    [Origen] varchar(30) NOT NULL,
    [Actor] nvarchar(256) NULL,
    [DetalleJson] nvarchar(max) NULL,
    [FechaEventoUTC] datetime2(3) CONSTRAINT [DF_DianDocumentoProceso_Fecha] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_DianDocumentoProcesoHistorial] PRIMARY KEY CLUSTERED ([ProcesoHistorialID]),
    CONSTRAINT [FK_DianDocumentoProceso_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
    CONSTRAINT [FK_DianDocumentoProceso_Carga] FOREIGN KEY ([CargaArchivoID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
    CONSTRAINT [CK_DianDocumentoProceso_Origen] CHECK ([Origen] IN ('POWER_AUTOMATE', 'FUNCTION', 'DIAN', 'USUARIO', 'SISTEMA')),
    CONSTRAINT [CK_DianDocumentoProceso_DetalleJson] CHECK ([DetalleJson] IS NULL OR ISJSON([DetalleJson]) = 1)
);
GO

CREATE INDEX [IX_DianDocumentoProceso_DocumentoFecha]
    ON [dian].[DocumentoProcesoHistorial] ([DocumentoID], [FechaEventoUTC] DESC);
GO
