# frozen_string_literal: true

module ActivePartition
  # Clase encargada de validar que el entorno y la configuración sean aptos
  # para el funcionamiento de ActivePartition.
  class SafetyGuard
    # Versión mínima de PostgreSQL soportada para particionamiento nativo estable.
    MIN_POSTGRES_VERSION = 13.0

    # Ejecuta todas las validaciones de seguridad.
    # @raise [ActivePartition::Error] Si alguna validación falla.
    # @return [void]
    def self.validate!
      check_configuration!
      return unless defined?(Rails) && Rails.env.to_s != 'test'

      check_database_adapter!
      check_postgres_version!
    end

    private

    # Verifica que la clave de partición esté presente.
    def self.check_configuration!
      if ActivePartition.configuration.partition_key.nil?
        raise ActivePartition::Error, "Falta configuración: 'partition_key' no ha sido definido."
      end
    end

    # Asegura que se esté utilizando PostgreSQL.
    def self.check_database_adapter!
      adapter = ActiveRecord::Base.connection_db_config.adapter
      unless adapter == "postgresql"
        raise ActivePartition::Error, "Adaptador incompatible: ActivePartition solo soporta PostgreSQL (usando: #{adapter})."
      end
    end

    # Verifica la versión de PostgreSQL mediante una consulta directa al motor.
    def self.check_postgres_version!
      version = ActiveRecord::Base.connection.select_value("SHOW server_version").to_f
      if version < MIN_POSTGRES_VERSION
        raise ActivePartition::Error, "Versión de PostgreSQL insuficiente: Se requiere v#{MIN_POSTGRES_VERSION}+ (detectada: #{version})."
      end
    rescue ActiveRecord::StatementInvalid
      # Si no hay conexión aún, se posterga la validación
    end
  end
end
