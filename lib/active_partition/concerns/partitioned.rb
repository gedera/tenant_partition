# frozen_string_literal: true

module ActivePartition
  module Concerns
    # Módulo para incluir en modelos de negocio (ApplicationRecord) que están particionados.
    #
    # @example
    #   class Message < ApplicationRecord
    #     include ActivePartition::Concerns::Partitioned
    #   end
    #
    #   # Uso automático:
    #   Message.for_partition("uuid-123").all
    module Partitioned
      extend ActiveSupport::Concern

      included do
        # Scope dinámico: lee la configuración global para saber qué columna filtrar
        scope :for_partition, ->(value) {
          key = ActivePartition.configuration.partition_key
          where(key => value)
        }
      end
    end
  end
end
