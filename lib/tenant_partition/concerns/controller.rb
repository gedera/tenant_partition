# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Concern para controladores que valida la presencia del Header de partición.
    module Controller
      extend ActiveSupport::Concern

      included do
        helper_method :current_partition_id if respond_to?(:helper_method)
      end

      # Obtiene el ID de partición desde los headers de la petición.
      # @return [String, nil] El valor del header configurado.
      def current_partition_id
        return @current_partition_id if defined?(@current_partition_id)

        header_key = TenantPartition.configuration.header_name
        return @current_partition_id = nil unless header_key.present?

        @current_partition_id = request.headers[header_key]
      end

      # Filtro before_action para forzar la presencia del tenant.
      # Renderiza un error 400 Bad Request si falta.
      def require_partition_key!
        return if current_partition_id.present?

        render json: {
          error: "Partitioning Error",
          message: missing_header_message
        }, status: :bad_request
      end

      private

      def missing_header_message
        header_key = TenantPartition.configuration.header_name
        if header_key.blank?
          "Server Configuration Error: 'header_name' is not configured in TenantPartition."
        else
          "Missing required header: '#{header_key}'"
        end
      end
    end
  end
end
