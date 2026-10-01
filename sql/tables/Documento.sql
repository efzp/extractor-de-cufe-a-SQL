SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[Documento]
(
    [DocumentoID] bigint IDENTITY(1,1) NOT NULL,
    [ClienteID] bigint NOT NULL,
    [ClaveDocumento] char(96) NOT NULL,
    [TipoClave] varchar(4) NOT NULL,
    [TipoDocumento] nvarchar(80) NOT NULL,
    [RevisionActual] int CONSTRAINT [DF_DianDocumento_RevisionActual] DEFAULT (1) NOT NULL,
    [EstadoRevision] varchar(20) CONSTRAINT [DF_DianDocumento_EstadoRevision] DEFAULT ('NO_REQUIERE') NOT NULL,
    [MotivoRevision] nvarchar(1000) NULL,
    [EstadoProceso] varchar(30) CONSTRAINT [DF_DianDocumento_EstadoProceso] DEFAULT ('REGISTRADO') NOT NULL,
    [PrimeraCargaID] bigint NOT NULL,
    [UltimaCargaID] bigint NOT NULL,
    [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_DianDocumento_FechaCreacion] DEFAULT (sysutcdatetime()) NOT NULL,
    [FechaActualizacionUTC] datetime2(3) CONSTRAINT [DF_DianDocumento_FechaActualizacion] DEFAULT (sysutcdatetime()) NOT NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianDocumento] PRIMARY KEY CLUSTERED ([DocumentoID]),
    CONSTRAINT [UQ_DianDocumento_ClienteClave] UNIQUE ([ClienteID], [ClaveDocumento]),
    CONSTRAINT [FK_DianDocumento_Cliente] FOREIGN KEY ([ClienteID]) REFERENCES [dian].[Cliente] ([ClienteID]),
    CONSTRAINT [FK_DianDocumento_PrimeraCarga] FOREIGN KEY ([PrimeraCargaID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
    CONSTRAINT [FK_DianDocumento_UltimaCarga] FOREIGN KEY ([UltimaCargaID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
    CONSTRAINT [CK_DianDocumento_Clave] CHECK
    (
        LEN([ClaveDocumento]) = 96 AND
        [ClaveDocumento] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%'
    ),
    CONSTRAINT [CK_DianDocumento_TipoClave] CHECK ([TipoClave] IN ('CUFE', 'CUDE')),
    CONSTRAINT [CK_DianDocumento_RevisionActual] CHECK ([RevisionActual] >= 1),
    CONSTRAINT [CK_DianDocumento_EstadoRevision] CHECK ([EstadoRevision] IN ('NO_REQUIERE', 'PENDIENTE', 'APROBADO', 'RECHAZADO')),
    CONSTRAINT [CK_DianDocumento_EstadoProceso] CHECK ([EstadoProceso] IN ('REGISTRADO', 'PENDIENTE_DESCARGA', 'CONSULTANDO_DIAN', 'XML_DESCARGADO', 'PROCESADO', 'NO_ENCONTRADO', 'REQUIERE_REVISION', 'ERROR'))
);
GO

CREATE INDEX [IX_DianDocumento_Cola]
    ON [dian].[Documento] ([EstadoProceso], [ClienteID], [DocumentoID]);
GO

CREATE INDEX [IX_DianDocumento_Revision]
    ON [dian].[Documento] ([EstadoRevision], [ClienteID], [DocumentoID]);
GO
