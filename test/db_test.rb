require 'test/test_helper'
require 'digest/md5'
require 'stringio'
require 'logger'

class TestPKFactory
  def create_pk(row)
    row['_id'] ||= BSON::ObjectID.new
    row
  end
end

class DBTest < Test::Unit::TestCase

  include Mongo

  @@host  = ENV['MONGO_RUBY_DRIVER_HOST'] || 'localhost'
  @@port  = ENV['MONGO_RUBY_DRIVER_PORT'] || Connection::DEFAULT_PORT
  @@conn  = Connection.new(@@host, @@port)
  @@db    = @@conn.db(MONGO_TEST_DB)
  @@users = @@db.collection('system.users')
  @@version = @@conn.server_version

  def test_close
    @@conn.close
    assert !@@conn.connected?
    begin
      @@db.collection('test').insert('a' => 1)
      fail "expected 'NilClass' exception"
    rescue => ex
      assert_match /NilClass/, ex.to_s
    ensure
      @@db = Connection.new(@@host, @@port).db(MONGO_TEST_DB)
      @@users = @@db.collection('system.users')
    end
  end
  
  def test_logger
    output = StringIO.new
    logger = Logger.new(output)
    logger.level = Logger::DEBUG
    conn = Connection.new(@host, @port, :logger => logger)
    assert_equal logger, conn.logger
    
    conn.logger.debug 'testing'
    assert output.string.include?('testing')
  end

  def test_full_coll_name
    coll = @@db.collection('test')
    assert_equal "#{MONGO_TEST_DB}.test", @@db.full_collection_name(coll.name)
  end

  def test_collection_names
    @@db.collection("test").insert("foo" => 5)
    @@db.collection("test.mike").insert("bar" => 0)

    colls = @@db.collection_names()
    assert colls.include?("test")
    assert colls.include?("test.mike")
    colls.each { |name|
      assert !name.include?("$")
    }
  end

  def test_collections
    @@db.collection("test.durran").insert("foo" => 5)
    @@db.collection("test.les").insert("bar" => 0)

    colls = @@db.collections()
    assert_not_nil colls.select { |coll| coll.name == "test.durran" }
    assert_not_nil colls.select { |coll| coll.name == "test.les" }
    assert_equal [], colls.select { |coll| coll.name == "does_not_exist" }

    assert_kind_of Collection, colls[0]
  end

  def test_pair
    @@conn.close
    @@users = nil
    @@conn  = Connection.paired([["this-should-fail", 27017], [@@host, @@port]])
    @@db    = @@conn[MONGO_TEST_DB]
    assert @@conn.connected?
  ensure
    unless @@conn.connected?
      @@conn = Connection.new(@@host, @@port)
      @@db   = @@conn.db(MONGO_TEST_DB)
    end
    @@users = @@db.collection('system.users')
  end

  def test_pk_factory
    db = Connection.new(@@host, @@port).db(MONGO_TEST_DB, :pk => TestPKFactory.new)
    coll = db.collection('test')
    coll.remove

    insert_id = coll.insert('name' => 'Fred', 'age' => 42)
    # new id gets added to returned object
    row = coll.find_one({'name' => 'Fred'})
    oid = row['_id']
    assert_not_nil oid
    assert_equal insert_id, oid

    oid = BSON::ObjectID.new
    data = {'_id' => oid, 'name' => 'Barney', 'age' => 41}
    coll.insert(data)
    row = coll.find_one({'name' => data['name']})
    db_oid = row['_id']
    assert_equal oid, db_oid
    assert_equal data, row

    coll.remove
  end

  def test_pk_factory_reset
    conn = Connection.new(@@host, @@port)
    db   = conn.db(MONGO_TEST_DB)
    db.pk_factory = Object.new # first time
    begin
      db.pk_factory = Object.new
      fail "error: expected exception"
    rescue => ex
      assert_match /Cannot change/, ex.to_s
    ensure
      conn.close
    end
  end

  def test_authenticate
    @@db.add_user('spongebob', 'squarepants')
    assert_raise Mongo::AuthenticationError do
      assert !@@db.authenticate('nobody', 'nopassword')
    end
    assert_raise Mongo::AuthenticationError do
      assert !@@db.authenticate('spongebob' , 'squareliederhosen')
    end
    assert @@db.authenticate('spongebob', 'squarepants')
    @@db.logout
    @@db.remove_user('spongebob')
  end

  def test_authenticate_with_connection_uri
    @@db.add_user('spongebob', 'squarepants')
    assert Mongo::Connection.from_uri("mongodb://spongebob:squarepants@localhost/#{@@db.name}")

    assert_raise Mongo::AuthenticationError do
      Mongo::Connection.from_uri("mongodb://wrong:info@localhost/#{@@db.name}")
    end
  end

  def test_logout
    assert @@db.logout
  end

  def test_error
    @@db.reset_error_history
    assert_nil @@db.error
    assert !@@db.error?
    assert_nil @@db.previous_error

    @@db.send(:command, :forceerror => 1)
    assert @@db.error?
    assert_not_nil @@db.error
    assert_not_nil @@db.previous_error

    @@db.send(:command, :forceerror => 1)
    assert @@db.error?
    assert @@db.error
    prev_error = @@db.previous_error
    assert_equal 1, prev_error['nPrev']
    assert_equal prev_error["err"], @@db.error

    @@db.collection('test').find_one
    assert_nil @@db.error
    assert !@@db.error?
    assert @@db.previous_error
    assert_equal 2, @@db.previous_error['nPrev']

    @@db.reset_error_history
    assert_nil @@db.error
    assert !@@db.error?
    assert_nil @@db.previous_error
  end

  if @@version >= "1.5.1"
    def test_failing_error_params
      assert_raise_error Mongo::MongoDBError, "timed out waiting for slaves" do
        @@db.error(:w => 2, :wtimeout => 10, :fsync => true)
      end
    end

    def test_passing_error_params
      assert_nil @@db.error(:w => 1, :wtimeout => 10, :fsync => true)
    end

    def test_invalid_error_params
      assert_raise_error ArgumentError, "Unknown key(s): z" do
        @@db.error(:z => 1, :wtimeout => 10, :fsync => true)
      end
    end
  end

  def test_check_command_response
    command = {:forceerror => 1}
    assert_raise OperationFailure do 
      @@db.command(command, false, true)
    end
  end

  def test_last_status
    @@db['test'].remove
    @@db['test'].save("i" => 1)

    @@db['test'].update({"i" => 1}, {"$set" => {"i" => 2}})
    assert @@db.last_status()["updatedExisting"]

    @@db['test'].update({"i" => 1}, {"$set" => {"i" => 500}})
    assert !@@db.last_status()["updatedExisting"]
  end

  def test_text_port_number_raises_no_errors
    conn = Connection.new(@@host, @@port.to_s)
    db   = conn[MONGO_TEST_DB]
    assert db.collection('users').remove
  end

  def test_user_management
    @@db.add_user("bob", "secret")
    assert @@db.authenticate("bob", "secret")
    @@db.logout
    assert @@db.remove_user("bob")
    assert_raise Mongo::AuthenticationError do
      @@db.authenticate("bob", "secret")
    end
  end

  def test_remove_non_existant_user
    assert !@@db.remove_user("joe")
  end


  if @@version >= "1.3.5"
    def test_db_stats
      stats = @@db.stats
      assert stats.has_key?('collections')
      assert stats.has_key?('dataSize')
    end
  end

  context "database profiling" do
    setup do
      @db  = @@conn[MONGO_TEST_DB]
      @coll = @db['test']
      @coll.remove
      @r1 = @coll.insert('a' => 1) # collection not created until it's used
    end

    should "set default profiling level" do
      assert_equal :off, @db.profiling_level
    end

    should "change profiling level" do
      @db.profiling_level = :slow_only
      assert_equal :slow_only, @db.profiling_level
      @db.profiling_level = :off
      assert_equal :off, @db.profiling_level
      @db.profiling_level = :all
      assert_equal :all, @db.profiling_level
      begin
        @db.profiling_level = :medium
        fail "shouldn't be able to do this"
      rescue
      end
    end

    should "return profiling info" do
      @db.profiling_level = :all
      @coll.find()
      @db.profiling_level = :off

      info = @db.profiling_info
      assert_kind_of Array, info
      assert info.length >= 1
      first = info.first
      assert_kind_of String, first['info']
      assert_kind_of Time, first['ts']
      assert_kind_of Numeric, first['millis']
    end

    should "validate collection" do
      doc = @db.validate_collection(@coll.name)
      assert_not_nil doc
      result = doc['result']
      assert_not_nil result
      assert_match /firstExtent/, result
    end

  end
end
