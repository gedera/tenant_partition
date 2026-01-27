# lib/tenant_partition/tasks/maintenance.rake
# frozen_string_literal: true

namespace :tenant_partition do
  desc "Audita todas las tablas DEFAULT definidas en TenantPartition"
  task audit: :environment do
    TenantPartition.audit
  end

  desc "Limpia registros huérfanos moviéndolos a sus particiones"
  task cleanup: :environment do
    TenantPartition.cleanup!
  end
end
