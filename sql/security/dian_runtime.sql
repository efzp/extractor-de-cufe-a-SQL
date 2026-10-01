SET XACT_ABORT ON;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals
    WHERE [name] = N'dian_runtime'
      AND [type] = 'R'
)
    EXEC(N'CREATE ROLE [dian_runtime] AUTHORIZATION [dbo];');
GO

-- No se conceden permisos generales sobre tablas al rol. Cada procedimiento
-- autorizado debe conceder EXECUTE explícitamente en su propio script.
