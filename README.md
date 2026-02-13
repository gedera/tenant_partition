# TenantPartition

**TenantPartition** es una solución robusta y "Rails-native" para implementar **Particionamiento Declarativo (List Partitioning)** de PostgreSQL en aplicaciones Ruby on Rails.

A diferencia de otras soluciones que dependen de esquemas (schemas) o hackeos a la conexión de base de datos, `tenant_partition` utiliza características nativas de PostgreSQL para dividir tablas gigantes en tablas físicas más pequeñas por tenant (Cliente, ISP, Organización, etc.), manteniendo la experiencia de desarrollo de ActiveRecord estándar.

## 🚀 Características Principales

* **API Simple (Opt-in):** Usa `partition_table` en tus modelos para activar la magia.
* **Migraciones Inteligentes:** Helper `create_partitioned_table` que maneja la complejidad de Postgres automáticamente.
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

## ⚙️ Configuración Inicial

### 1. Inicializador
Crea un archivo para definir tu clave de partición global (por ejemplo, `:isp_id`, `:account_id`, `:tenant_id`).

```ruby
# config/initializers/tenant_partition.rb

TenantPartition.configure do |config|
  # Esta es la columna que actuará como discriminador global
  config.partition_key = :isp_id
end
```

### 2. Habilitar en ApplicationRecord
Incluye el concern en tu modelo base. **No te preocupes, esto no particiona nada por defecto**, solo habilita la posibilidad de usar la macro `partition_table` en tus modelos.

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Habilita la herramienta (modo inactivo por defecto)
  include TenantPartition::Concerns::Partitioned
end
```

---

## 🛠 Guía de Implementación

### Paso 1: Migración de Base de Datos

Olvídate del SQL manual. Usa el helper `create_partitioned_table` que hace todo el trabajo sucio por ti:
1.  Crea la tabla padre con `PARTITION BY LIST`.
2.  Configura la Primary Key Compuesta `[:id, :partition_key]`.
3.  Crea automáticamente la partición `_default` para capturar datos no asignados.

#### Opción A: Usando Enteros (BigInt) - Recomendado

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    # partition_key: usa el default de la config (:isp_id) si no se especifica.
    # id_type: :bigint por defecto.
    create_partitioned_table :conversations do |t|
      t.string :subject
      t.text :body
      t.timestamps

      # Nota: No definas :id ni :isp_id aquí, el helper lo hace por ti.
    end
  end
end
```

#### Opción B: Usando UUIDs

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    enable_extension 'pgcrypto' # Necesario para gen_random_uuid()

    create_partitioned_table :conversations, id_type: :uuid do |t|
      t.string :subject
      t.timestamps
    end
  end
end
```

### Paso 2: Configurar el Modelo

Usa la macro `partition_table` para activar la funcionalidad en el modelo correspondiente.

```ruby
# app/models/conversation.rb
class Conversation < ApplicationRecord
  # ¡Esto es todo!
  # Automáticamente configura la Primary Key compuesta [:id, :isp_id]
  # y los scopes necesarios.
  partition_table
end
```

**¿Necesitas una key diferente para un solo modelo?**
```ruby
class AuditLog < ApplicationRecord
  # Este modelo se particiona por año, ignorando la config global
  partition_table key: :year
end
```

### Paso 3: Crear y Eliminar Tenants

Gestiona el ciclo de vida de las particiones utilizando los métodos de clase inyectados.

```ruby
# Crear partición física para el ISP con ID 100
Conversation.create_partition(100)
# => Crea la tabla "conversations_isp_100"

# Verificar si existe
Conversation.partition_table_exists?(100)
# => true

# Eliminar partición (CUIDADO: Borra datos)
Conversation.drop_partition(100)
# => Elimina "conversations_isp_100"
```

#### Automatización con Callbacks
Es común crear las particiones automáticamente cuando nace un nuevo Tenant.

```ruby
# app/models/isp.rb
class Isp < ApplicationRecord
  after_create :provision_infrastructure

  def provision_infrastructure
    # Helper global que crea particiones en TODOS los modelos registrados
    TenantPartition.create!(self.id)
  end
end
```

---

## 🧹 Mantenimiento y Datos Huérfanos

Si insertas datos con un `isp_id` para el cual no has creado una partición, Postgres los guardará en la tabla `_default` que creamos en la migración. `TenantPartition` incluye herramientas para detectar y corregir esto.

### Auditoría
Verifica si tienes datos "mal ubicados" en las tablas default:

```bash
bundle exec rake tenant_partition:audit
# [TenantPartition] [AUDIT] Iniciando auditoría...
# [TenantPartition] [ALERTA] Conversation: 450 registros huérfanos encontrados.
```

### Limpieza (Cleanup)
Crea las particiones faltantes y mueve los datos automáticamente a su hogar correcto:

```bash
bundle exec rake tenant_partition:cleanup
# [TenantPartition] [FIX] Conversation: Procesando 2 tenants con datos huérfanos.
# [TenantPartition] [MOVE] -> ID 101: 450 registros recuperados.
```

---

## 🛡️ Producción y Seguridad

La gema incluye un `SafetyGuard` que impide ejecutar comandos destructivos (`drop_partition`, `destroy!`) en entorno de producción para evitar catástrofes.

Si realmente necesitas borrar un tenant en producción, debes autorizarlo explícitamente:

```bash
DISABLE_TENANT_PARTITION_GUARD=true bundle exec rake tenant_partition:destroy_tenant[123]
```

---

## 📖 Referencia de API

### `TenantPartition` (Global)
* `configure { ... }`: Configuración inicial.
* `create!(id)`: Crea particiones para el ID dado en **todos** los modelos registrados.
* `destroy!(id)`: Elimina particiones para el ID dado en **todos** los modelos.
* `exists?(id)`: Devuelve `true` si existe infraestructura para ese ID.

### Métodos de Instancia (Modelos)
* `partition_table(key: nil)`: Macro de activación.

### Métodos de Clase (Modelos)
* `create_partition(value)`: Crea tabla física.
* `drop_partition(value)`: Borra tabla física.
* `partition_table_exists?(value)`: Verifica existencia.
* `partition_table_name(value)`: Devuelve el nombre real de la tabla en Postgres.

---

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
