## [Unreleased]

## [0.2.0] - 2026-02-13
### Changed (Breaking Changes)
- **Arquitectura:** Se eliminó la clase `TenantPartition::Base` y la necesidad de crear modelos de infraestructura en el namespace `Partition::`.
- **Integración:** Ahora se utiliza un concern `TenantPartition::Concerns::Partitioned` y la macro `partition_table` directamente en los modelos de dominio.

### Added
- Macro `partition_table` para activar particionamiento de forma declarativa (Opt-In).
- Soporte para claves primarias compuestas (Composite Primary Keys) nativas de Rails 7.1+.
- Nuevo sistema de "Registry" interno para el descubrimiento de modelos particionados (reemplaza a `ObjectSpace`).
- Métodos de clase `create_partition`, `drop_partition` y `partition_table_exists?` inyectados directamente en el modelo.
- Documentación actualizada con estrategias de inclusión (Global vs Local).

### Fixed
- Corrección de ofensas de RuboCop en métodos largos de generación SQL.
- Mejoras en la seguridad de tipos en la orquestación de tareas de mantenimiento.

## [0.1.2] - 2026-02-03
### Added
- Nuevo generador `rails g tenant_partition:api_controller` para crear endpoints de aprovisionamiento.
- Soporte para namespaces dinámicos en el generador (ej: `rails g tenant_partition:api_controller Ops`).

## [0.1.1] - 2026-01-27
- Refactor: Rename internal module to `TenantPartition`.
- Fix: Update Rake tasks and Notifications to use `tenant_partition` namespace.

## [0.1.0] - 2026-01-26
- Initial release
