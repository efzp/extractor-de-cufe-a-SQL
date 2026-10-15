-- Ejecutar en un lote separado, despues de crear ml.sp_RegistrarPrediccionPlantilla.
-- La Function puede registrar predicciones sin acceso directo a tablas o vistas.
IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'
    THROW 50920, 'Base de datos inesperada para permisos ML.', 1;

IF OBJECT_ID(N'ml.sp_RegistrarPrediccionPlantilla', N'P') IS NULL
    THROW 50921, 'Falta ml.sp_RegistrarPrediccionPlantilla.', 1;

GRANT EXECUTE ON OBJECT::[ml].[sp_RegistrarPrediccionPlantilla] TO [dian_runtime];
