SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[ConsultaDian]
(
    [ConsultaDianID] bigint IDENTITY(1,1) NOT NULL,
    [DocumentoID] bigint NOT NULL,
    [NumeroIntento] smallint NOT NULL,
    [FechaInicioUTC] datetime2(3) CONSTRAINT [DF_DianConsulta_FechaInicio] DEFAULT (sysutcdatetime()) NOT NULL,
    [FechaFinUTC] datetime2(3) NULL,
    [Estado] varchar(20) NOT NULL,
    [CodigoDian] nvarchar(50) NULL,
    [MensajeDianSanitizado] nvarchar(1000) NULL,
    [HttpStatus] smallint NULL,
    [DuracionMs] int NULL,
    [CorrelationID] uniqueidentifier CONSTRAINT [DF_DianConsulta_Correlation] DEFAULT (newsequentialid()) NOT NULL,
    [ErrorTipo] nvarchar(100) NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianConsulta] PRIMARY KEY CLUSTERED ([ConsultaDianID]),
    CONSTRAINT [UQ_DianConsulta_Intento] UNIQUE ([DocumentoID], [NumeroIntento]),
    CONSTRAINT [UQ_DianConsulta_Correlation] UNIQUE ([CorrelationID]),
    CONSTRAINT [FK_DianConsulta_Documento] FOREIGN KEY ([DocumentoID]) REFERENCES [dian].[Documento] ([DocumentoID]),
    CONSTRAINT [CK_DianConsulta_NumeroIntento] CHECK ([NumeroIntento] >= 1),
    CONSTRAINT [CK_DianConsulta_Estado] CHECK ([Estado] IN ('INICIADA', 'OK', 'NO_ENCONTRADO', 'ERROR', 'REINTENTO')),
    CONSTRAINT [CK_DianConsulta_Duracion] CHECK ([DuracionMs] IS NULL OR [DuracionMs] >= 0)
);
GO

CREATE INDEX [IX_DianConsulta_DocumentoFecha]
    ON [dian].[ConsultaDian] ([DocumentoID], [FechaInicioUTC] DESC);
GO
