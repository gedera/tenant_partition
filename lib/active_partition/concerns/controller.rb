# frozen_string_literal: true

module ActivePartition
  module Concerns
    # Helpers y validaciones para controladores en arquitecturas Multi-tenant.
    #
    # Este módulo implementa una estrategia de extracción estricta:
    # Solo acepta el ID de partición si viene en el Header HTTP configurado explícitamente.
    #
    # @example Configuración requerida
    #   # config/initializers/active_partition.rb
    #   ActivePartition.configure do |config|
    #     config.partition_key = :isp_id
    #     config.header_name = 'X-Tenant-ID' # <--- Obligatorio
    #   end
    #
    # @example Uso en el controlador
    #   class ApiController < ActionController::API
    #     include ActivePartition::Concerns::Controller
    #     before_action :require_partition_key!
    #   end
    module Controller
      extend ActiveSupport::Concern

      included do
        # Expone el método a las vistas de Rails (erb, jbuilder, etc.)
        helper_method :current_partition_id if respond_to?(:helper_method)
      end

      # Devuelve el valor del ID de partición actual extraído exclusivamente de los Headers.
      #
      # Utiliza únicamente el nombre de header definido en +ActivePartition.configuration.header_name+.
      # No realiza inferencias ni busca en parámetros de la URL.
      #
      # @return [String, nil] El valor del header o nil si no está presente o configurado.
      def current_partition_id
        return @current_partition_id if defined?(@current_partition_id)

        header_key = ActivePartition.configuration.header_name

        # Si no se configuró un nombre de header, no podemos buscar nada.
        return @current_partition_id = nil unless header_key.present?

        @current_partition_id = request.headers[header_key]
      end

      # Filtro (before_action) para detener la ejecución si el ID de partición no está presente.
      #
      # Retorna un error 400 Bad Request si el header falta.
      #
      # @return [void]
      def require_partition_key!
        return if current_partition_id.present?

        header_key = ActivePartition.configuration.header_name

        # Mensaje de error detallado dependiendo de si es un error de configuración o de petición
        error_message = if header_key.blank?
                          "Server Configuration Error: 'header_name' is not configured in ActivePartition."
                        else
                          "Missing required header: '#{header_key}'"
                        end

        render json: {
          error: "Partitioning Error",
          message: error_message
        }, status: :bad_request
      end
    end
  end
end
