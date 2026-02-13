# TenantPartition

**TenantPartition** es una solución robusta y "Rails-native" para implementar **Particionamiento Declarativo (List Partitioning)** de PostgreSQL en aplicaciones Ruby on Rails.

A diferencia de otras soluciones que dependen de esquemas (schemas) o hackeos a la conexión de base de datos, `tenant_partition` utiliza características nativas de PostgreSQL para dividir tablas gigantes en tablas físicas más pequeñas por tenant (Cliente, ISP, Organización, etc.), manteniendo la experiencia de desarrollo de ActiveRecord estándar.

## 🚀 Características Principales

* **API Simple (Opt-in):** Usa `partition_table` en tus modelos para activar la magia.
* **Soporte Nativo CPK:** Compatible con **Composite Primary Keys** de Rails 7.1+.
* **Sin Magic Strings:** Usa métodos explícitos (`create_partition`, `drop_partition`).
* **Gestión de Datos Huérfanos:** Herramientas para mover datos de la tabla "Default" a su partición correcta automáticamente.
* **Safety Guards:** Protección contra borrados accidentales en Producción.
* **Tasks de Mantenimiento:** Rake tasks integradas para auditoría y limpieza.

---

## 📦 Instalación

Agrega esto a tu `Gemfile`:

```ruby
gem 'tenant_partition'
```

Y ejecuta:

```bash
bundle install
```

---

## ⚙️ Configuración

Crea un inicializador para definir tu clave de partición global (por ejemplo, `:isp_id`, `:account_id`, `:tenant_id`).

```ruby
# config/initializers/tenant_partition.rb

TenantPartition.configure do |config|
  # Esta es la columna que actuará como discriminador global
  config.partition_key = :isp_id
end
```

### Habilitar en ApplicationRecord (Recomendado)

Para tener disponible la macro en todos tus modelos, incluye el concern en tu modelo base. **No te preocupes, esto no particiona nada por defecto.**

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  
  # Habilita la macro 'partition_table', pero no se activa 
  # hasta que la llames explícitamente en una subclase.
  include TenantPartition::Concerns::Partitioned
end
```

---

## 🛠 Guía de Uso

### 1. Migración de Base de Datos

PostgreSQL necesita que la tabla padre se cree con la opción `PARTITION BY LIST`. Además, **debes incluir la partition key en la Primary Key**.

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def up
    # 1. Crear la tabla padre particionada
    # Nota: id: false porque definiremos una CPK manual
    create_table :conversations, id: false, options: "PARTITION BY LIST (isp_id)" do |t|
      t.bigserial :id, null: false
      t.integer :isp_id, null: false # Tu partition key
      
      t.string :subject
      t.text :body
      t.timestamps
    end

    # 2. Definir la Primary Key Compuesta (Requerido por Postgres para particionar)
    execute "ALTER TABLE conversations ADD PRIMARY KEY (id, isp_id);"

    # 3. Crear una tabla DEFAULT (Opcional pero recomendado para datos huérfanos)
    execute "CREATE TABLE conversations_default PARTITION OF conversations DEFAULT;"
  end

  def down
    drop_table :conversations
  end
end
```

### 2. Configurar el Modelo

Usa la macro `partition_table` para activar la funcionalidad.

```ruby
# app/models/conversation.rb
class Conversation < ApplicationRecord
  # ¡Esto es todo! 
  # Automáticamente configura la Primary Key compuesta [:id, :isp_id]
  # y los scopes necesarios.
  partition_table 
end
```

#### ¿Necesitas una key diferente para un solo modelo?
```ruby
class AuditLog < ApplicationRecord
  # Este modelo se particiona por año, ignorando la config global
  partition_table key: :year
end
```

### 3. Crear y Eliminar Tenants

Gestiona el ciclo de vida de las particiones utilizando los métodos de clase inyectados. Esto es ideal para callbacks en tu modelo `Tenant` o `Isp`.

```ruby
# Ejemplo: Crear partición para el ISP con ID 100
Conversation.create_partition(100)
# => Crea la tabla física "conversations_isp_100"

# Verificar si existe
Conversation.partition_table_exists?(100)
# => true

# Eliminar partición (CUIDADO: Borra datos)
Conversation.drop_partition(100)
# => Elimina "conversations_isp_100"
```

#### Ejemplo en un Callback de ISP:

```ruby
# app/models/isp.rb
class Isp < ApplicationRecord
  after_create :provision_partitions
  
  def provision_partitions
    # Helper global para crear particiones en TODOS los modelos registrados
    TenantPartition.create!(self.id)
  end
end
```

---

## 🧹 Mantenimiento y Datos Huérfanos

Si insertas datos con un `isp_id` para el cual no has creado una partición (y tienes una tabla `DEFAULT`), los datos caerán ahí. `TenantPartition` incluye herramientas para moverlos a su lugar correcto.

### Auditoría
Verifica si tienes datos en las tablas default:

```bash
bundle exec rake tenant_partition:audit
# [TenantPartition] [AUDIT] Iniciando auditoría...
# [TenantPartition] [ALERTA] Conversation: 450 registros huérfanos encontrados.
```

### Limpieza (Cleanup)
Crea las particiones faltantes y mueve los datos automáticamente:

```bash
bundle exec rake tenant_partition:cleanup
# [TenantPartition] [FIX] Conversation: Procesando 2 tenants con datos huérfanos.
# [TenantPartition] [MOVE] -> ID 101: 450 registros recuperados.
```

También puedes hacerlo manualmente desde la consola:

```ruby
# Mueve datos del tenant 101 desde Default hacia su partición
Conversation.create_partition(101) # Asegurar que existe destino
mover = Conversation.new(isp_id: 101)
mover.populate_from_default
```

---

## 🛡️ Producción y Seguridad

La gema incluye un `SafetyGuard` que impide ejecutar comandos destructivos (`drop_partition`, `destroy!`) en entorno de producción a menos que se fuerce explícitamente.

Para ejecutar tareas destructivas en producción, debes setear la variable de entorno:

```bash
DISABLE_TENANT_PARTITION_GUARD=true bundle exec rake tenant_partition:destroy_tenant[123]
```

---

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
