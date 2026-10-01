SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[CargaDocumento]
(
    [CargaArchivoID] bigint NOT NULL,
    [FilaOrigen] int NOT NULL,
    [DocumentoID] bigint NULL,
    [DocumentoVersionID] bigint NULL,
    [HashFilaSha256] char(64) NULL,
    [FilaOrigenJson] nvarchar(max) NOT NULL,
    [EsValida] bit CONSTRAINT [DF_DianCargaDocumento_EsValida] DEFAULT (0) NOT NULL,
    [Resultado] varchar(20) NOT NULL,
    [ErrorValidacion] nvarchar(1000) NULL,
    [FechaRegistroUTC] datetime2(3) CONSTRAINT [DF_DianCargaDocumento_FechaRegistro] DEFAULT (sysutcdatetime()) NOT NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianCargaDocumento] PRIMARY KEY CLUSTERED ([CargaArchivoID], [FilaOrigen]),
    CONSTRAINT [FK_DianCargaDocumento_Carga] FOREIGN KEY ([CargaArchivoID]) REFERENCES [dian].[CargaArchivo] ([CargaArchivoID]),
    CONSTRAINT [FK_DianCargaDocumento_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
    CONSTRAINT [FK_DianCargaDocumento_Version] FOREIGN KEY ([DocumentoVersionID]) REFERENCES [dian].[DocumentoVersion] ([DocumentoVersionID]),
    CONSTRAINT [CK_DianCargaDocumento_Fila] CHECK ([FilaOrigen] >= 2),
    CONSTRAINT [CK_DianCargaDocumento_Json] CHECK (ISJSON([FilaOrigenJson]) = 1),
    CONSTRAINT [CK_DianCargaDocumento_Resultado] CHECK ([Resultado] IN ('NUEVO', 'DUPLICADO', 'NUEVA_REVISION', 'RECHAZADO'))
);
GO

CREATE INDEX [IX_DianCargaDocumento_Documento]
    ON [dian].[CargaDocumento] ([DocumentoID], [CargaArchivoID]);
GO
