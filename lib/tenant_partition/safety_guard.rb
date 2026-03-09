# frozen_string_literal: true

module TenantPartition
  # Clase interna encargada de validar prerequisitos del entorno y base de datos.
  class SafetyGuard
    # Versión mínima de PostgreSQL requerida.
    MIN_POSTGRES_VERSION = 13.0

    class << self
      # Ejecuta todas las validaciones de seguridad.
      # @raise [TenantPartition::Error] Si alguna validación falla.
      def validate!
        check_configuration!
        return unless defined?(Rails) && Rails.env.to_s != "test"

        check_postgres_version!
      end

      private

      def check_configuration!
        return unless TenantPartition.configuration.partition_key.nil?

        raise TenantPartition::Error, "Falta configuración: 'partition_key' no ha sido definido."
      end

      def check_postgres_version!
        version = ActiveRecord::Base.connection.select_value("SHOW server_version").to_f
        return if version >= MIN_POSTGRES_VERSION

        raise TenantPartition::Error, "Versión de PostgreSQL insuficiente: Se requiere " \
                                      "v#{MIN_POSTGRES_VERSION}+ (detectada: #{version})."
      rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
        # Si no hay conexión aún, se posterga la validación hasta el primer uso real
      end
    end
  end
end
