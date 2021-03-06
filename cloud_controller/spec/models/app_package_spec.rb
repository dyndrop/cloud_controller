require 'spec_helper'
require 'tmpdir'

describe AppPackage do
  before :all do
    EM.instance_variable_set(:@next_tick_queue, [])
  end

  describe '#resolve_path' do
    before(:all) do
      @tmpdir = Dir.mktmpdir
      @dummy_zip = Tempfile.new('app_package_test')
      @app_package = AppPackage.new(nil, @dummy_zip)
    end

    after(:all) do
      FileUtils.rm_rf @tmpdir
    end

    it 'should succeed if the given path points to a file in the apps directory' do
      testpath = File.join(@tmpdir,'testfile')
      File.new(testpath, 'w+')
      @app_package.resolve_path(@tmpdir, 'testfile').should == File.realdirpath(testpath)
    end

    it 'should fail if the given path does not resolve to a file in the applications directory' do
      expect do
       @app_package.resolve_path(@tmpdir, '../foo')
      end.to raise_error(ArgumentError)
    end

    it 'should fail if the given path contains a symlink that points outside of the applications directory' do
      Dir.chdir(@tmpdir) {
        File.symlink('/etc', 'foo')
      }
      expect do
       @app_package.resolve_path(@tmpdir, 'foo/bar')
      end.to raise_error(ArgumentError)
    end
  end

  describe "#create_dir_skeleton" do
    before :each do
      @app_package = AppPackage.new(nil, nil)
      @working_dir = Dir.mktmpdir
    end

    after :each do
      FileUtils.rm_rf(@working_dir)
    end

    it "should raise an error if the resource points outside of the app" do
      [ "../outside", "../../outside", "../././../outside"].each do |resource|
        expect do
          @app_package.create_dir_skeleton("/a/b", resource)
        end.to raise_error(AppPackageError, /points outside/)
      end
    end

    it "should create the directory skeleton if the resource points inside the app" do
      ["foo/bar/baz.rb", "bar/../bar/baz/jaz.rb"].each do |resource|
        @app_package.create_dir_skeleton(@working_dir, resource)
      end

      File.directory?(File.join(@working_dir, "foo/bar")).should be_true
      File.directory?(File.join(@working_dir, "bar/baz")).should be_true
    end

    it "should not create a directory in the place of a file resource" do
      @app_package.create_dir_skeleton(@working_dir, "foo/bar/baz.rb")

      File.directory?(File.join(@working_dir, "foo/bar/baz.rb")).should be_false
      File.exists?(File.join(@working_dir, "foo/bar/baz.rb")).should be_false
    end
  end

  describe '#unpack_upload' do
    it 'should raise an instance of AppPackageError if unzip exits with a nonzero status code' do
      invalid_zip = Tempfile.new('app_package_test')
      app_package = AppPackage.new(nil, invalid_zip)
      em do
        Fiber.new do
          expect do
            app_package.send(:unpack_upload)
          end.to raise_error(AppPackageError)
          EM.stop
        end.resume
      end
    end
  end

  describe '#get_unzipped_size' do
    before :each do
      @tmpdir = Dir.mktmpdir
    end

    after :each do
      FileUtils.rm_rf(@tmpdir)
    end

    it 'should raise an instance of AppPackageError if unzip exits with a nonzero status' do
      invalid_zip = Tempfile.new('unzipped_size_test')
      app_package = AppPackage.new(nil, invalid_zip)
      em do
        Fiber.new do
          expect do
            app_package.send(:get_unzipped_size)
          end.to raise_error(AppPackageError, /Failed listing/)
          EM.stop
        end.resume
      end
    end

    it 'should return the total size of the unzipped droplet' do
      [1, 5].each do |file_count|
        zipname = File.join(@tmpdir, "test#{file_count}.zip")
        unzipped_size = create_zip(zipname, file_count)
        app_package = AppPackage.new(nil, File.new(zipname))
        computed_size = nil
        em do
          Fiber.new do
            computed_size = app_package.send(:get_unzipped_size)
            EM.stop
          end.resume
        end
        computed_size.should == unzipped_size
      end
    end
  end

  describe '#check_package_size' do
    before :each do
      @tmpdir = Dir.mktmpdir
      @saved_size = AppConfig[:max_droplet_size]
      @saved_pool = CloudController.resource_pool
    end

    after :each do
      FileUtils.rm_rf(@tmpdir)
      AppConfig[:max_droplet_size] = @saved_size
      CloudController.resource_pool = @saved_pool
    end

    it 'should raise an instance of AppPackageError if the unzipped size is too large' do
      zipname = File.join(@tmpdir, "test.zip")
      unzipped_size = create_zip(zipname, 10, 1024)
      app_package = AppPackage.new([], File.new(zipname))
      AppConfig[:max_droplet_size] = unzipped_size - 1024
      em do
        Fiber.new do
          expect do
            app_package.send(:check_package_size)
          end.to raise_error(AppPackageError, /exceeds/)
          EM.stop
        end.resume
      end
    end

    it 'should raise an instance of AppPackageError if the total size is too large' do
      CloudController.resource_pool = FilesystemPool.new(:directory => @tmpdir)
      tf = Tempfile.new('mytemp')
      tf.write("A" * 1024)
      tf.close
      CloudController.resource_pool.add_path(tf.path)
      sha1 = Digest::SHA1.file(tf.path).hexdigest
      zipname = File.join(@tmpdir, "test.zip")
      unzipped_size = create_zip(zipname, 1, 1024)
      app_package = AppPackage.new(nil, File.new(zipname), [{:sha1 => sha1, :fn => 'test/path'}])
      AppConfig[:max_droplet_size] = unzipped_size + 512
      em do
        Fiber.new do
          expect do
            app_package.send(:check_package_size)
          end.to raise_error(AppPackageError, /exceeds/)
          EM.stop
        end.resume
      end

    end
  end

  describe '.blocking_defer' do
    it 'should result the result of the deferred operation' do
      deferred_result = nil
      em do
        Fiber.new do
          deferred_result = AppPackage.blocking_defer { 'hi' }
          EM.stop
        end.resume
      end
      deferred_result.should == 'hi'
    end

    it 'should propagate exceptions raised inside the deferred block out to the calling fiber' do
      deferred_result = nil
      em do
        Fiber.new do
          expect do
            deferred_result = AppPackage.blocking_defer { raise "HI" }
          end.to raise_error(RuntimeError)
          EM.stop
        end.resume
      end
    end
  end

  describe '.repack_app_in' do
    it 'should raise an instance of AppPackageError if zipping the application fails' do
      nonexistant_dir = Dir.mktmpdir
      FileUtils.rm_rf(nonexistant_dir)
      em do
        Fiber.new do
          expect do
            AppPackage.repack_app_in(nonexistant_dir, nonexistant_dir, :zip)
          end.to raise_error(AppPackageError)
          EM.stop
        end.resume
      end
    end

    it 'should repack files that start with a dot using zip or tar' do
      app_dir = Dir.mktmpdir
      tmp_dir = Dir.mktmpdir
      zip_extract_dir = Dir.mktmpdir
      tar_extract_dir = Dir.mktmpdir

      git_directory_path = File.join(app_dir, '.git')
      FileUtils.mkdir(git_directory_path)

      app_files = ['.gitignore', '.htaccess', 'index.php']
      app_files.each do |filename|
        FileUtils.touch(File.join(app_dir, filename))
      end

      em do
        Fiber.new do
          packaged_app_path = AppPackage.repack_app_in(app_dir, tmp_dir, :zip)
          `unzip #{packaged_app_path} -d #{zip_extract_dir}`
          unpacked_zip_files = Dir.entries(zip_extract_dir)
          unpacked_zip_files.should include(*app_files, File.basename(git_directory_path))

          packaged_app_path = AppPackage.repack_app_in(app_dir, tmp_dir, :tar)
          `tar -zxf #{packaged_app_path} -C #{tar_extract_dir}`
          unpacked_tar_files = Dir.entries(tar_extract_dir)
          unpacked_tar_files.should include(*app_files, File.basename(git_directory_path))

          EM.stop
        end.resume
      end
    end
  end

  def em(timeout=5)
    EM.run do
      EM.add_timer(timeout) { EM.stop }
      yield
    end
  end

  def create_zip(zip_name, file_count, file_size=1024)
    total_size = file_count * file_size
    files = []
    file_count.times do |ii|
      tf = Tempfile.new("ziptest_#{ii}")
      files << tf
      tf.write("A" * file_size)
      tf.close
    end
    system("zip #{zip_name} #{files.map(&:path).join(' ')}").should be_true
    total_size
  end
end
