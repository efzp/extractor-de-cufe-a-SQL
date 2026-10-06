-- Ejecutar después de instalar los cuatro procedimientos de extracción.
GRANT EXECUTE ON OBJECT::[dian].[sp_ObtenerXmlParaExtraccion] TO [dian_runtime];
GRANT EXECUTE ON OBJECT::[dian].[sp_ListarXmlPendientesExtraccion] TO [dian_runtime];
GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarExtraccionXml] TO [dian_runtime];
GRANT EXECUTE ON OBJECT::[dian].[sp_RegistrarErrorExtraccionXml] TO [dian_runtime];
