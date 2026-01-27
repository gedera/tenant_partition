# lib/active_partition/tasks/maintenance.rake
# frozen_string_literal: true

namespace :active_partition do
  desc "Audita todas las tablas DEFAULT definidas en ActivePartition"
  task audit: :environment do
    ActivePartition.audit
  end

  desc "Limpia registros huérfanos moviéndolos a sus particiones"
  task cleanup: :environment do
    ActivePartition.cleanup!
  end
end
