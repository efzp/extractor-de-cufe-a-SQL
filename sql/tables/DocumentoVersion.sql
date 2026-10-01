SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[DocumentoVersion]
(
    [DocumentoVersionID] bigint IDENTITY(1,1) NOT NULL,
    [DocumentoID] bigint NOT NULL,
    [NumeroRevision] int NOT NULL,
    [HashContenidoSha256] char(64) NOT NULL,
    [TipoDocumentoOrigen] nvarchar(80) NOT NULL,
    [Folio] nvarchar(50) NOT NULL,
    [Prefijo] nvarchar(30) NULL,
    [Divisa] nvarchar(10) NULL,
    [FormaPago] nvarchar(20) NULL,
    [MedioPago] nvarchar(20) NULL,
    [FechaEmision] date NOT NULL,
    [FechaRecepcion] datetime2(0) NOT NULL,
    [NitEmisor] nvarchar(20) NOT NULL,
    [NombreEmisor] nvarchar(300) NOT NULL,
    [NitReceptor] nvarchar(20) NOT NULL,
    [NombreReceptor] nvarchar(300) NOT NULL,
    [Iva] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Iva] DEFAULT (0) NOT NULL,
    [Ica] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Ica] DEFAULT (0) NOT NULL,
    [Ic] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Ic] DEFAULT (0) NOT NULL,
    [Inc] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Inc] DEFAULT (0) NOT NULL,
    [Timbre] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Timbre] DEFAULT (0) NOT NULL,
    [IncBolsas] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_IncBolsas] DEFAULT (0) NOT NULL,
    [InCarbono] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_InCarbono] DEFAULT (0) NOT NULL,
    [InCombustibles] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_InCombustibles] DEFAULT (0) NOT NULL,
    [IcDatos] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_IcDatos] DEFAULT (0) NOT NULL,
    [Icl] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Icl] DEFAULT (0) NOT NULL,
    [Inpp] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Inpp] DEFAULT (0) NOT NULL,
    [Ibua] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Ibua] DEFAULT (0) NOT NULL,
    [Icui] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_Icui] DEFAULT (0) NOT NULL,
    [ReteIva] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_ReteIva] DEFAULT (0) NOT NULL,
    [ReteRenta] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_ReteRenta] DEFAULT (0) NOT NULL,
    [ReteIca] decimal(19,4) CONSTRAINT [DF_DianDocumentoVersion_ReteIca] DEFAULT (0) NOT NULL,
    [Total] decimal(19,4) NOT NULL,
    [EstadoDianOrigen] nvarchar(100) NOT NULL,
    [GrupoOrigen] nvarchar(50) NOT NULL,
    [EstadoRevision] varchar(20) CONSTRAINT [DF_DianDocumentoVersion_EstadoRevision] DEFAULT ('NO_REQUIERE') NOT NULL,
    [MotivoRevision] nvarchar(1000) NULL,
    [RevisadoPor] nvarchar(256) NULL,
    [FechaRevisionUTC] datetime2(3) NULL,
    [EsRevisionVigente] bit CONSTRAINT [DF_DianDocumentoVersion_EsVigente] DEFAULT (0) NOT NULL,
    [CargaCreacionID] bigint NOT NULL,
    [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_DianDocumentoVersion_FechaCreacion] DEFAULT (sysutcdatetime()) NOT NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianDocumentoVersion] PRIMARY KEY CLUSTERED ([DocumentoVersionID]),
    CONSTRAINT [UQ_DianDocumentoVersion_Numero] UNIQUE ([DocumentoID], [NumeroRevision]),
    CONSTRAINT [UQ_DianDocumentoVersion_Hash] UNIQUE ([DocumentoID], [HashContenidoSha256]),
    CONSTRAINT [FK_DianDocumentoVersion_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
    CONSTRAINT [FK_DianDocumentoVersion_Carga] FOREIGN KEY ([CargaCreacionID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
    CONSTRAINT [CK_DianDocumentoVersion_Numero] CHECK ([NumeroRevision] >= 1),
    CONSTRAINT [CK_DianDocumentoVersion_EstadoRevision] CHECK ([EstadoRevision] IN ('NO_REQUIERE', 'PENDIENTE', 'APROBADO', 'RECHAZADO'))
);
GO

CREATE UNIQUE INDEX [UX_DianDocumentoVersion_Vigente]
    ON [dian].[DocumentoVersion] ([DocumentoID])
    WHERE [EsRevisionVigente] = 1;
GO
