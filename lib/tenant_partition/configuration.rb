# frozen_string_literal: true

# Namespace principal de la gema.
module TenantPartition
  # Clase contenedora de la configuración global de la gema.
  class Configuration
    # @return [Symbol, nil] Columna de base de datos usada para particionar (ej: :isp_id).
    attr_accessor :partition_key

    # @return [String, nil] Nombre del Header HTTP para identificación (ej: 'X-Tenant-ID').
    attr_accessor :header_name

    def initialize
      @partition_key = nil
      @header_name = nil
    end

    # Valida si la configuración mínima requerida está presente.
    # @return [Boolean] true si es válida.
    def valid?
      !partition_key.nil?
    end
  end

  class << self
    # @return [TenantPartition::Configuration] La instancia actual de configuración.
    attr_accessor :configuration

    # Punto de entrada para configurar la gema.
    # @yieldparam [TenantPartition::Configuration] config
    # @raise [TenantPartition::Error] Si la configuración resultante es inválida.
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)

      return if configuration.valid?

      raise TenantPartition::Error, "Debe configurar un 'partition_key' en el inicializador de TenantPartition."
    end
  end
end
