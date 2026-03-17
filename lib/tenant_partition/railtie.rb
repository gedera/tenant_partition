# frozen_string_literal: true

require "rails/railtie"

module TenantPartition
  # Railtie encargado de integrar TenantPartition en el ciclo de vida de Rails.
  #
  # Su responsabilidad principal es inyectar los componentes de la gema (Tareas Rake,
  # Helpers de Migración) en la aplicación anfitriona durante el proceso de arranque.
  class Railtie < Rails::Railtie
    # Bloque para cargar tareas Rake.
    # Debe estar definido DENTRO de la clase Railtie para tener acceso al método +rake_tasks+.
    #
    # Carga las tareas de mantenimiento (audit, cleanup) para que estén
    # disponibles mediante el comando `rails`.
    rake_tasks do
      # Usamos expand_path para asegurar que la ruta sea absoluta respecto a la gema,
      # evitando errores de "file not found" dependiendo de dónde se ejecute el comando.
      Dir[File.expand_path("tasks/*.rake", __dir__)].each do |file|
        load file
      end
    end

    # Inicializador que se ejecuta cuando Rails carga los componentes de ActiveRecord.
    #
    # Inyecta los helpers de migración (como +create_partitioned_table+) directamente
    # en el adaptador de PostgreSQL para extender el DSL de las migraciones.
    initializer "tenant_partition.insert_schema_statements" do
      ActiveSupport.on_load(:active_record) do
        require "tenant_partition/schema/statements"

        # Validación de seguridad:
        # Solo inyectamos el módulo si el adaptador configurado es efectivamente PostgreSQL.
        # Esto previene errores si la gema se instala en proyectos con MySQL o SQLite.
        if defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
          ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.include TenantPartition::Schema::Statements
        end
      end
    end
  end
end
