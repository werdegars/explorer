class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  def home
    @title = 'Home'
    @output = ApplicationController::cli('getinfo')
    @output = JSON.parse(@output)
  
    @latest_blocks = Array.new
    blocks = @output["blocks"] - 6
    @output["blocks"].downto(blocks).each do |n|
      block = ApplicationController::get_block(n)
      total_sent = 0
      block["tx"].each do |txid|
        transaction = get_transaction(txid)
        transaction["vout"].each do |vout|
          total_sent += vout["value"]
        end
      end
      block["total_sent"] = total_sent
      @latest_blocks << block
    end
    if ENV['COIN_NAME'] == 'Namecoin'
      @latest_transactions = JSON.parse(ApplicationController::cli(['name_filter', '^[i]?d/', '6']))
      @latest_transactions.each_with_index do |tx, index|
        @latest_transactions[index]["age"] = ApplicationController::get_block(@latest_transactions[index]["height"])["time"]
        details = get_transaction(@latest_transactions[index]["txid"])
        details["vout"].each do |vout|
          if vout["scriptPubKey"] && vout["scriptPubKey"]["nameOp"] && vout["scriptPubKey"]["nameOp"]["name"] == @latest_transactions[index]["name"]
            @latest_transactions[index]["operation"] = vout["scriptPubKey"]["nameOp"]["op"]
            break
          end
        end
      end
      @latest_transactions = @latest_transactions.sort_by {|k| k["age"]}.reverse
    end
  end

  def api
    @title = 'API'
  end

  # Dynamic routes start here

  def search
    query = params[:query]    
    if query.downcase.start_with?('d/') || query.downcase.start_with?('id/')
      redirect_to "/name/#{query}"
    elsif query.downcase.end_with?('.bit')
      redirect_to "/name/d/#{query[0..-5]}"
    elsif query.length == 64
      redirect_to "/tx/#{query}"
    elsif query.count('g-zG-Z') > 0
      redirect_to "/address/#{query}"
    elsif query.count('a-fA-F') > 0
      redirect_to "/block/#{query}"
    elsif query.count('a-fA-F') == 0
      redirect_to "/block/#{query}"
    else
      redirect_to '/404'
    end
  end

  def block
    @title = "Block #{params[:block]}"
    @output = ApplicationController::get_block(params[:block])

    @name_operations = Array.new
    if ENV['COIN_NAME'] == 'Namecoin'
      txids = @output["tx"]
      txids.each do |txid|
        details = get_transaction(txid)
        details["vout"].each do |vout|
          if vout["scriptPubKey"] && vout["scriptPubKey"]["nameOp"] && vout["scriptPubKey"]["nameOp"]["name"]
            @name_operations << vout["scriptPubKey"]["nameOp"]
            @name_operations[-1]["txid"] = txid
          end
        end
      end
    end

    @output["totals"] = {"output" => 0, "input" => 0}
    @output["tx"].each_with_index do |txid, index|
      @output["tx"][index] = get_transaction(txid, true, true)
      @output["totals"]["output"] += @output["tx"][index]["totals"]["output"]
      @output["totals"]["input"] += @output["tx"][index]["totals"]["input"]
    end
  end

  def transaction
    @title = "Transaction #{params[:transaction]}"
    @output = get_transaction(params[:transaction], true, true)
    @output["height"] = ApplicationController::get_block(@output["blockhash"])["height"]
  end

  def address
    @title = "Address #{params[:address]}"
    @address = Address.where(address: params[:address])

    if Block.where(ended: true).order('block desc').first != ApplicationController::cli('getblockcount').to_i
      index_latest_blocks()
    end

    @complete_data = Block.where(ended: true).count == ApplicationController::cli('getblockcount').to_i

    if @address
      @balance = 0
      @address.each do |a|
        @balance += a.credit if a.credit
        @balance -= a.debit if a.debit
        a.balance = @balance
      end
    end
  end

  def name
    @title = "Name #{params[:name]}"
    params[:type] = params[:type].downcase
    params[:name] = params[:name].downcase
    if params[:type] == 'd'
      @output = ApplicationController::cli(['name_show', 'd/' + params[:name]])
      @history = ApplicationController::cli(['name_history', 'd/' + params[:name]])
    elsif params[:type] == 'id'
      @output = ApplicationController::cli(['name_show', 'id/' + params[:name]])
      @history = ApplicationController::cli(['name_history', 'id/' + params[:name]])
    end
      
    if !@output.include?('name not found')
      @output = JSON.parse(@output)
      @history = JSON.parse(@history)

      @history.each_with_index do |transaction, index|
        @history[index]["time"] = ApplicationController::get_block(transaction["height"])["time"]
        details = get_transaction(transaction["txid"])
        details["vout"].each do |vout|
          if vout["scriptPubKey"] && vout["scriptPubKey"]["nameOp"] && vout["scriptPubKey"]["nameOp"]["name"]
            @history[index]["op"] = vout["scriptPubKey"]["nameOp"]["op"]
          end
        end
      end

      @history.reverse!
    else
      @output = nil
      @history = nil
    end
  end

  def index_latest_blocks
    old_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil

    total_blocks = ApplicationController::cli('getblockcount').to_i
    first_block = Block.where(ended: true).order('block desc').first
    if first_block
      first_block = first_block.block
    else
      first_block = 1
    end

    (first_block..total_blocks).each do |block|
      if !Block.where(block: block, started: true, ended: true).first
        begin
          block_hash = ApplicationController::cli(['getblockhash', block.to_s])
          b = Block.create(block: block, blockhash: block_hash, started: true)
          txids = JSON.parse(ApplicationController::cli(['getblock', block_hash]))["tx"]

          txids.each do |txid|
            begin
              tx = JSON.parse(ApplicationController::cli(["getrawtransaction", txid, '1']))
            rescue
              puts txid
            end

            tx["vin"].each do |vin|
              if vin["prevTransaction"]
                Address.create(address: vin["prevTransaction"]["vout"][vin["vout"]]["scriptPubKey"]["addresses"][0], txid: tx['txid'], debit: vin["prevTransaction"]["vout"][vin["vout"]]["value"])
              end
            end

            tx["vout"].each do |vout|
              Address.create(address: vout["scriptPubKey"]["addresses"][0], txid: tx['txid'], credit: vout["value"])
            end
          end

          b.update(ended: true)
        rescue Exception => e
          puts "FAILED ON BLOCK #{block}"
        end
      end
    end
  end

  def self.cli(command)
    require 'open3'
    stdout_and_stderr_str, status = Open3.capture2e({'rpcuser' => ENV['RPC_USER'], 'rpcpassword' => ENV['RPC_PASSWORD'], 'rpcport' => ENV['RPC_PORT']}, ENV['CLI'], *command)
    return stdout_and_stderr_str
  end

  def get_transaction(txid, include_input_transactions = false, include_totals = false)
    output = JSON.parse(ApplicationController::cli(["getrawtransaction", txid, '1']))
    if include_input_transactions
      output["vin"].each_with_index do |vin, index|
        if vin["txid"]
          output["vin"][index]["prevTransaction"] = get_transaction(vin["txid"])
        end
      end
      if include_totals
        output["totals"] = {"output" => 0, "input" => 0}
        output["vin"].each do |vin|
          if vin["prevTransaction"]
            output["totals"]["input"] += vin["prevTransaction"]["vout"][vin["vout"]]["value"]
          end
        end
        output["vout"].each_with_index do |vout, index|
          output["totals"]["output"] += vout["value"]
        end
      end      
    end
    return output
  end

  def self.get_block(block)
    if block.to_s.count('a-fA-F') > 0
      JSON.parse(ApplicationController::cli(['getblock', block]))
    else
      hash = ApplicationController::cli(['getblockhash', block.to_s])
      JSON.parse(ApplicationController::cli(['getblock', hash]) 
      )
    end
  end

  # API Routes start here

  def api_getbestblockhash
    render plain: ApplicationController::cli('getbestblockhash')
  end

  def api_getblockchaininfo
    render json: ApplicationController::cli('getblockchaininfo')
  end

  def api_getblockcount
    render plain: ApplicationController::cli('getblockcount')
  end

  def api_getdifficulty
    render plain: ApplicationController::cli('getdifficulty')
  end

  def api_getmempoolinfo
    render json: ApplicationController::cli('getmempoolinfo')
  end

  def api_getinfo
    render json: ApplicationController::cli('getinfo')
  end

  def api_getmininginfo
    render json: ApplicationController::cli('getmininginfo')
  end

  def api_ping
    render json: ApplicationController::cli('ping')
  end

  def api_listbanned
    render json: ApplicationController::cli('listbanned')
  end

  def api_getpeerinfo
    render json: ApplicationController::cli('getpeerinfo')
  end

  def api_getnetworkinfo
    render json: ApplicationController::cli('getnetworkinfo')
  end

  def api_getchaintips
    render json: ApplicationController::cli('getchaintips')
  end

  def api_getnettotals
    render json: ApplicationController::cli('getnettotals')
  end

  def api_getconnectioncount
    render json: ApplicationController::cli('getconnectioncount')
  end

  def api_gettxoutsetinfo
    render json: ApplicationController::cli('gettxoutsetinfo')
  end

  def api_getblockhash
    render plain: ApplicationController::cli(['getblockhash', params[:index].to_s])
  end

  def api_getblock
    render json: ApplicationController::cli(['getblock', params[:hash]])
  end

  def api_getblockheader
    render json: ApplicationController::cli(['getblockheader', params[:hash]])
  end

  def api_getmempoolancestors
    render json: ApplicationController::cli(['getmempoolancestors', params[:txid]])
  end

  def api_getmempoolentry
    render json: ApplicationController::cli(['getmempoolentry', params[:txid]])
  end

  def api_getmempooldescendants
    render json: ApplicationController::cli(['getmempooldescendants', params[:txid]])
  end

  def api_getrawmempool
    render json: ApplicationController::cli('getrawmempool')
  end

  def api_namefilter
#    render json: ApplicationController::cli(['name_filter'])
  end

  def api_namehistory
    render json: ApplicationController::cli(['name_history', params[:name]])
  end

  def api_namepending
    render json: ApplicationController::cli(['name_pending', params[:name].to_s])
  end

  def api_nameshow
    render json: ApplicationController::cli(['name_show', params[:name]])
  end

  def api_getrawtransaction
    render plain: ApplicationController::cli(['getrawtransaction', params[:txid]])
  end
end
