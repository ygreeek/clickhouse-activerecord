class CreateSomeDictionary < ActiveRecord::Migration[5.0]
  def change
    options = <<~SQL
      PRIMARY KEY id
      SOURCE(FILE(path '/var/lib/clickhouse/user_files/test.json' format 'JSONEachRow'))
      LAYOUT(FLAT)
      LIFETIME(300)
    SQL

    create_dictionary :some_dictionary, with_table: :some_table, options: options do |t|
      t.integer :id, limit: 5, null: false
      t.string :name, null: false
      t.string :inn, null: false
      t.integer :ctn, limit: 5, null: false
    end
  end
end
