# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module TenantPartition
  module Generators
    # Generador de la Fase 1 (Preparación) para migraciones Zero-Downtime.
    #
    # Este generador crea la infraestructura inicial necesaria para comenzar a migrar
    # una tabla legacy hacia una tabla particionada sin tiempo de inactividad.
    # Específicamente, genera una migración que clona la estructura de la tabla
    # original y establece los triggers de PostgreSQL para la sincronización en vivo (Live Sync).
    #
    # @example Generar migración de preparación para la tabla 'versions'
    #   rails g tenant_partition:prepare versions isp_id
    class PrepareGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      # @!attribute [r] table_name
      #   @return [String] El nombre de la tabla legacy que se desea migrar.
      argument :table_name, type: :string, banner: "nombre_de_la_tabla_actual"

      # @!attribute [r] partition_key
      #   @return [String] El nombre de la columna que actuará como clave de partición.
      argument :partition_key, type: :string, banner: "columna_partition_key"

      desc "Genera la Fase 1 (Preparación): Crea la tabla sombra y los triggers de Live Sync."

      # Método requerido por Rails::Generators::Migration para la nomenclatura de archivos.
      # Determina el siguiente número (timestamp) para el archivo de migración.
      #
      # @param dirname [String] El directorio donde se guardarán las migraciones.
      # @return [String] El prefijo numérico para el archivo.
      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      # Crea el archivo de migración de preparación en la carpeta db/migrate.
      # Utiliza la plantilla prepare_online_migration.rb.erb.
      #
      # @return [void]
      def create_preparation_migration
        migration_template(
          "prepare_online_migration.rb.erb",
          "db/migrate/prepare_online_migration_for_#{table_name}.rb",
          migration_version: migration_version
        )
      end

      # Muestra en consola las instrucciones de los siguientes pasos
      # una vez que el generador termina de ejecutarse exitosamente.
      #
      # @return [void]
      def show_readme
        readme "PREPARE_README" if behavior == :invoke
      end

      private

      # Obtiene la versión actual de ActiveRecord para inyectarla en la sintaxis de la migración.
      #
      # @return [String] Ejemplo: "[7.1]"
      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      # Construye el nombre de la tabla destino (sombra) que recibirá los datos.
      #
      # @return [String] Ejemplo: "versions_partitioned"
      def target_table
        "#{table_name}_partitioned"
      end
    end
  end
end
