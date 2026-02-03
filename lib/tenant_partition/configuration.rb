# frozen_string_literal: true

module TenantPartition
  # Objeto de configuración global de la gema.
  class Configuration
    # @return [Symbol, nil] Columna de base de datos usada para particionar (ej: :isp_id).
    attr_accessor :partition_key

    # @return [String, nil] Nombre del Header HTTP para identificación (ej: 'X-Tenant-ID').
    attr_accessor :header_name

    def initialize
      @partition_key = nil
      @header_name = nil
    end

    # @return [Boolean] true si la configuración mínima es válida.
    def valid?
      !partition_key.nil?
    end
  end

  class << self
    attr_accessor :configuration

    # Bloque de configuración principal.
    # @raise [TenantPartition::Error] Si la configuración es inválida.
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)

      return if configuration.valid?

      raise TenantPartition::Error, "Debe configurar un 'partition_key' en el inicializador de TenantPartition."
    end
  end
end
