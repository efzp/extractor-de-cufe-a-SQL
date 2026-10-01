SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE TABLE [dian].[Cliente]
(
    [ClienteID] bigint IDENTITY(1,1) NOT NULL,
    [Nit] nvarchar(20) NOT NULL,
    [RazonSocial] nvarchar(300) NOT NULL,
    [Estado] varchar(10) CONSTRAINT [DF_DianCliente_Estado] DEFAULT ('ACTIVO') NOT NULL,
    [FechaCreacionUTC] datetime2(3) CONSTRAINT [DF_DianCliente_FechaCreacion] DEFAULT (sysutcdatetime()) NOT NULL,
    [FechaActualizacionUTC] datetime2(3) CONSTRAINT [DF_DianCliente_FechaActualizacion] DEFAULT (sysutcdatetime()) NOT NULL,
    [RowVersion] rowversion NOT NULL,
    CONSTRAINT [PK_DianCliente] PRIMARY KEY CLUSTERED ([ClienteID]),
    CONSTRAINT [UQ_DianCliente_Nit] UNIQUE ([Nit]),
    CONSTRAINT [CK_DianCliente_Estado] CHECK ([Estado] IN ('ACTIVO', 'INACTIVO'))
);
GO
