## [Unreleased]

## [0.3.0] - 2026-03-09
### Added (Zero-Downtime Migrations)
- **Migraciones Online:** Nueva suite de herramientas para migrar tablas masivas en producción sin tiempo de inactividad (Zero-Downtime).
- **Schema Statements:** Se agregaron los helpers `create_partition_sync_trigger`, `remove_partition_sync_trigger` y `swap_partitioned_tables` para manejar el Live Sync mediante Triggers de base de datos y Cutover atómico.
- **Backfill Engine (`TenantPartition::Migrator`):** Nueva clase para mover millones de registros en segundo plano. Incluye resolución automática de conflictos (`UPSERT`) para convivir con la replicación en vivo, y soporte nativo de paginación por fechas (`created_at`) para tablas que usan UUIDs.
- **Generador de Rails:** Nuevo comando `rails g tenant_partition:online_migration` que genera automáticamente las migraciones de 5 fases necesarias para migrar una tabla de forma segura.
- **Rake Tasks:** Nueva tarea `rake tenant_partition:backfill_data` para ejecutar el copiado de datos fácilmente desde la consola o background jobs.

### Changed
- **Railtie:** Se actualizó la carga de tareas Rake para incluir dinámicamente todos los archivos `.rake` del directorio `tasks/`, permitiendo que coexistan las tareas de mantenimiento y migración.

## [0.2.1] - 2026-02-13
### Added
- **Mejora en Migraciones:** El helper `create_partitioned_table` ahora acepta la opción `id_type: :uuid` o `id_type: :bigint` (por defecto). Esto permite usar particionamiento con IDs enteros seriales estándar o UUIDs según la necesidad del proyecto.

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
