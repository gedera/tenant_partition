# frozen_string_literal: true

module ActivePartition
  # Clase responsable de almacenar la configuración global de ActivePartition.
  #
  # @attribute [rw] partition_key
  #   @return [Symbol, nil] El nombre de la columna utilizada para particionar.
  #     Debe ser configurado explícitamente en el inicializador.
  class Configuration
    attr_accessor :partition_key

    # Inicializa una nueva configuración. No define un valor por defecto para
    # garantizar que la gema sea agnóstica al dominio.
    def initialize
      @partition_key = nil
    end

    # Verifica si la configuración mínima necesaria está presente.
    # @return [Boolean]
    def valid?
      !partition_key.nil?
    end
  end

  class << self
    # @return [ActivePartition::Configuration]
    attr_accessor :configuration

    # Configura la gema mediante un bloque.
    #
    # @yieldparam [ActivePartition::Configuration] config
    # @example
    #   ActivePartition.configure do |config|
    #     config.partition_key = :tenant_id
    #   end
    #
    # @raise [ActivePartition::Error] Si no se define un partition_key.
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)

      unless configuration.valid?
        raise ActivePartition::Error, "Debe configurar un 'partition_key' en el inicializador de ActivePartition."
      end
    end
  end
end
