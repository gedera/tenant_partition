## [Unreleased]

## [0.1.3] - 2026-02-03
### Changed
- Generator: Se simplificó el controlador API generado (se eliminó la acción `show` y el manejo de errores por defecto).
- Fix: Se restringieron las versiones de `activemodel` y `activerecord` a `< 9.0` para evitar advertencias de RubyGems.

## [0.1.2] - 2026-02-03
### Added
- Nuevo generador `rails g tenant_partition:api_controller` para crear endpoints de aprovisionamiento.
- Soporte para namespaces dinámicos en el generador (ej: `rails g tenant_partition:api_controller Ops`).

## [0.1.1] - 2026-01-27
- Refactor: Rename internal module to `TenantPartition`.
- Fix: Update Rake tasks and Notifications to use `tenant_partition` namespace.

## [0.1.0] - 2026-01-26
- Initial release
