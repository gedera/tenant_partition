# frozen_string_literal: true

module TenantPartition
  class Configuration
    # @return [Symbol, nil] Columna de base de datos (ej: :isp_id)
    attr_accessor :partition_key

    # @return [String, nil] Nombre del Header HTTP personalizado (ej: 'X-Tenant-ID')
    attr_accessor :header_name

    def initialize
      @partition_key = nil
      @header_name = nil
    end

    def valid?
      !partition_key.nil?
    end
  end

  class << self
    attr_accessor :configuration

    def configure
      self.configuration ||= Configuration.new
      yield(configuration)

      unless configuration.valid?
        raise TenantPartition::Error, "Debe configurar un 'partition_key' en el inicializador de TenantPartition."
      end
    end
  end
end
