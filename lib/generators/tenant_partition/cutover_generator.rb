# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module TenantPartition
  module Generators
    # Generador de la Fase 2 (Cutover) para migraciones Zero-Downtime.
    #
    # Este generador crea la migración final necesaria para completar el proceso de
    # particionamiento en vivo. La migración generada se encarga de realizar un
    # intercambio atómico (Swap) a nivel de PostgreSQL: renombra la tabla legacy a
    # un nombre de respaldo, y activa la tabla particionada (sombra) con el nombre original,
    # eliminando al mismo tiempo los triggers de sincronización temporal.
    #
    # @example Generar migración de cutover para la tabla 'versions'
    #   rails g tenant_partition:cutover versions isp_id
    class CutoverGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      # @!attribute [r] table_name
      #   @return [String] El nombre de la tabla legacy original.
      argument :table_name, type: :string, banner: "nombre_de_la_tabla_actual"

      # @!attribute [r] partition_key
      #   @return [String] El nombre de la columna utilizada como clave de partición.
      argument :partition_key, type: :string, banner: "columna_partition_key"

      desc "Genera la Fase 2 (Cutover): Intercambia las tablas de forma atómica y elimina triggers."

      # Método requerido por Rails::Generators::Migration para la nomenclatura de archivos.
      # Determina el siguiente número (timestamp) para el archivo de migración.
      #
      # @param dirname [String] El directorio donde se guardarán las migraciones.
      # @return [String] El prefijo numérico para el archivo.
      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      # Crea el archivo de migración de cutover en la carpeta db/migrate.
      # Utiliza la plantilla complete_online_migration.rb.erb.
      #
      # @return [void]
      def create_cutover_migration
        migration_template(
          "complete_online_migration.rb.erb",
          "db/migrate/complete_online_migration_for_#{table_name}.rb",
          migration_version: migration_version
        )
      end

      # Muestra en consola las instrucciones críticas y advertencias de seguridad
      # una vez que el generador termina de ejecutarse exitosamente.
      #
      # @return [void]
      def show_readme
        readme "CUTOVER_README" if behavior == :invoke
      end

      private

      # Obtiene la versión actual de ActiveRecord para inyectarla en la sintaxis de la migración.
      #
      # @return [String] Ejemplo: "[7.1]"
      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      # Construye el nombre de la tabla destino (sombra) que ahora pasará a ser la principal.
      #
      # @return [String] Ejemplo: "versions_partitioned"
      def target_table
        "#{table_name}_partitioned"
      end
    end
  end
end
