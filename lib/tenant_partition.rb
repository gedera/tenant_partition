# frozen_string_literal: true

require_relative "tenant_partition/version"
require_relative "tenant_partition/configuration"
# ELIMINADO: require_relative "tenant_partition/base"
require_relative "tenant_partition/concerns/partitioned"

# Módulo principal de la gema TenantPartition.
# Configura y coordina el particionamiento de tablas en PostgreSQL.
module TenantPartition
  class Error < StandardError; end

  class << self
    attr_accessor :configuration

    # Array para almacenar los modelos que han activado el particionamiento.
    # @return [Array<Class>] Lista de clases ActiveRecord.
    def registered_models
      @registered_models ||= []
    end

    # Registra un modelo como particionado.
    # @api private
    # @param model [Class] La clase del modelo a registrar.
    def register_model(model)
      registered_models << model
      registered_models.uniq!
    end

    # Devuelve la lista de modelos particionados activos.
    # @return [Array<Class>]
    def partitionable_models
      registered_models
    end

    # Bloque de configuración global.
    # @yield [configuration]
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
    end
  end
end
