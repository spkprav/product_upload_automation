require "spree_upload_products/version"
require 'csv'

module SpreeUploadProducts
  class ProductsCsv
    def initialize(csv_path)
      @csv_products = ::CSV.parse(File.read(csv_path), headers: true, skip_blanks: true)
      @random = []
    end

    def add_product
      default_shipping_category = Spree::ShippingCategory.find_by_name!("Default")
      @csv_products.each do |row|
        product = Spree::Product.where(name: row['Product Name'].try(:strip)).first
        product = if product.present?
                    product.description = row['Product Description'].try(:strip)
                    product.price = row['Master Price'].try(:strip).to_f
                    product.sku = "#{Rails.application.class.parent_name}-#{product.id}-#{token}-00" unless product.sku.present?
                    product.save
                    product
                  else
                    count = Spree::Product.last.id + 1
                    product = Spree::Product.create(
                      name: row['Product Name'].try(:strip),
                      description: row['Product Description'].try(:strip),
                      available_on: DateTime.current,
                      shipping_category_id: default_shipping_category.id,
                      price: row['Master Price'].try(:strip).to_f,
                      sku: "#{Rails.application.class.parent_name}-#{count}-#{token}-00"
                    )
                  end
        if product.present?
          add_taxons(row, product) if row['Product Category'].present?
          if row['Customizable Type'].present?
            combination = add_option_type(row, product)
            add_variant(combination, product, row)
          end
          add_master(product, row)
        end
      end
    end

    def add_taxons(row, product)
      parent = row['Product Category'].split('|').first.try(:strip).try(:gsub, /[^0-9A-Za-z]/, ' ').upcase
      child = row['Product Category'].split('|').last.try(:strip).try(:gsub, /[^0-9A-Za-z]/, ' ').upcase
      taxonomy = Spree::Taxonomy.where(name: parent).first
      taxonomy = Spree::Taxonomy.create(name: parent) unless taxonomy.present?
      parent_taxon = ''
      row['Product Category'].split('|').each do |t|
        next if t.blank? || t.nil?
        t = t.try(:strip).try(:gsub, /[^0-9A-Za-z]/, ' ').upcase
        taxon = taxonomy.taxons.where(name: t).first
        taxon = taxonomy.taxons.create(name: t, parent_id: parent_taxon) unless taxon.present?
        parent_taxon = taxon.id
      end
      taxon = taxonomy.taxons.find_by_name(child)
      product.classifications.destroy_all
      product.classifications.create(taxon_id: taxon.id)
    end

    def add_option_type(row, product)
      combination = []
      previous_value = []
      row['Customizable Type'].split('|').each do |t|
        next if t.blank? || t.nil?
        data = []
        type = t.split(':').first.try(:strip)
        option_type = Spree::OptionType.where(name: type).first
        option_type = Spree::OptionType.create(name: type, presentation: type.try(:capitalize)) unless option_type.present?
        t.split(':').last.split(',').each do |val|
          next if val.blank? || val.nil?
          val = val.try(:strip).try(:gsub, /[^0-9A-Za-z]/, ' ')
          option_value = option_type.option_values.where(name: val).first
          option_value = option_type.option_values.create(name: val, presentation: val.try(:capitalize)) unless option_value.present?
          if previous_value.include? type
            index = previous_value.find_index(type)
            combination[index] << option_value
          else
            data << option_value
          end
        end
        product.product_option_types.find_or_create_by(option_type_id: option_type.id)
        combination << data if data.present?
        previous_value << type
      end
      combination
    end

    def add_variant(combination, product, row)
      combination = combination.first.product(*combination[1..-1])

      existing_variants = product.variants.map{|a| a.option_values }
      combination.each_with_index do |val, index|
        next if existing_variants.map{ |a| a.sort === val.sort }.include?(true)
        variant = Spree::Variant.create(product: product, option_values: val, sku: "#{Rails.application.class.parent_name}-#{product.id}-#{token}-0#{index+1}", cost_price: product.price)
        add_stock(variant, row)
      end

      product.variants.each do |v|
        v.cost_price = product.price.to_f
        v.price = product.price.to_f
        v.save
      end
    end

    def add_master(product, row)
      variant = product.master
      add_stock(variant, row)
    end

    def add_stock(variant, row)
      location_name = row['Stock Location'].present? ? row['Stock Location'].try(:strip) : 'default'
      stock_location = Spree::StockLocation.where(name: location_name).first
      return unless stock_location.present?
      stock_movement = stock_location.stock_movements.build(quantity: row['quantity'].try(:strip).to_i)
      stock_movement.stock_item = stock_location.set_up_stock_item(variant)
      stock_movement.save
    end

    def token
      num = 0
      loop do
        num = "#{"%03d" % rand(00000000...99999999)}"
        unless @random.include?(num)
          @random << num
          break num
        end
      end
      num
    end
  end
end
