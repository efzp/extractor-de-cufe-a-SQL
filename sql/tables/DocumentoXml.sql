SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[DocumentoXml]
(
    [DocumentoXmlID] bigint IDENTITY(1,1) NOT NULL,
    [DocumentoID] bigint NOT NULL,
    [ConsultaDianID] bigint NOT NULL,
    [BlobUri] nvarchar(1000) NOT NULL,
    [HashXmlSha256] char(64) NOT NULL,
    [TamanoBytes] bigint NOT NULL,
    [TipoContenido] nvarchar(100) CONSTRAINT [DF_DianDocumentoXml_TipoContenido] DEFAULT ('application/xml') NOT NULL,
    [TipoXmlDetectado] nvarchar(80) NULL,
    [FechaAlmacenamientoUTC] datetime2(3) CONSTRAINT [DF_DianDocumentoXml_Fecha] DEFAULT (sysutcdatetime()) NOT NULL,
    [EsVigente] bit CONSTRAINT [DF_DianDocumentoXml_EsVigente] DEFAULT (1) NOT NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianDocumentoXml] PRIMARY KEY CLUSTERED ([DocumentoXmlID]),
    CONSTRAINT [UQ_DianDocumentoXml_Hash] UNIQUE ([DocumentoID], [HashXmlSha256]),
    CONSTRAINT [FK_DianDocumentoXml_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
    CONSTRAINT [FK_DianDocumentoXml_Consulta] FOREIGN KEY ([ConsultaDianID]) REFERENCES [dian].[ConsultaDian] ([ConsultaDianID]),
    CONSTRAINT [CK_DianDocumentoXml_Tamano] CHECK ([TamanoBytes] >= 0)
);
GO

CREATE UNIQUE INDEX [UX_DianDocumentoXml_Vigente]
    ON [dian].[DocumentoXml] ([DocumentoID])
    WHERE [EsVigente] = 1;
GO
