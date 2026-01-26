# frozen_string_literal: true

require "active_record"
require "active_model"
require "active_support/all"

# Carga de la versión
require_relative "active_partition/version"

# Requerimientos internos de la gema
require_relative "active_partition/configuration"
require_relative "active_partition/safety_guard"
require_relative "active_partition/base"

# Integración con Ruby on Rails
require_relative "active_partition/railtie" if defined?(Rails)

# ActivePartition es un framework para la gestión de particionamiento por lista (List Partitioning)
# en PostgreSQL, diseñado para aplicaciones Multi-tenant en Ruby on Rails.
#
# Proporciona abstracciones para la creación de infraestructura, migración de datos
# y mantenimiento de tablas particionadas siguiendo las convenciones de Rails.
#
# @see ActivePartition::Base
module ActivePartition
  # Error base para todas las excepciones de la gema.
  class Error < StandardError; end

  class << self
    # @return [ActivePartition::Configuration] El objeto de configuración global.
    attr_accessor :configuration

    # Configura la gema mediante un bloque. Es indispensable definir el partition_key.
    #
    # @yieldparam [ActivePartition::Configuration] config
    # @example
    #   ActivePartition.configure do |config|
    #     config.partition_key = :isp_id
    #   end
    #
    # @return [void]
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)

      # Una vez configurado, ejecutamos el SafetyGuard para validar el entorno
      SafetyGuard.validate!
    end
  end
end
