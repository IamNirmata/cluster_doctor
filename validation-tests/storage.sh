apt-get update && apt-get install -y fio

echo "Setting up storage test directory..."
echo "GCRNODE: $GCRNODE"
#california timrstamp
timestamp=$(date +%Y%m%d_%H%M%S -d 'TZ="America/Los_Angeles" now')
echo "Timestamp: $timestamp"
mkdir -p /data/storage_tests/output/$GCRNODE/$timestamp
echo "Storage test directory set up at /data/storage_tests/output/$GCRNODE/$timestamp"

cd /data/storage_tests/
echo pwd: $(pwd)
echo "Current directory contents:"
ls -l


# numjobs read nfiles test
# fio numjobs_read_nfiles.fio --output-format=json --output=/data/storage_tests/output/numjobs_read_nfiles.json


# Numjobs write nfiles test
# fio numjobs_write_nfiles.fio --output-format=json --output=/data/storage_tests/output/numjobs_write_nfiles.json

# Iodepth read 1file test
# fio iodepth_read_1file.fio --output-format=json --output=/data/storage_tests/output/iodepth_read_1file.json

# Iodepth write 1file test
# fio iodepth_write_1file.fio --output-format=json --output=/data/storage_tests/output/iodepth_write_1file.json

# Random read test
# fio randread.fio --output-format=json --output=/data/storage_tests/output/randread.json

# Random write test
# fio randwrite.fio --output-format=json --output=/data/storage_test/output/randwrite.json


#write test then read test
echo "Starting storage tests..."

echo "Running random write test...1/6 tests"
fio randwrite.fio --output-format=json --output=/data/storage_tests/output/$GCRNODE/$timestamp/randwrite.json
echo "Running random read test...2/6 tests"
fio randread.fio --output-format=json --output=/data/storage_tests/output/$GCRNODE/$timestamp/randread.json

echo "Running iodepth write test...3/6 tests"
fio iodepth_write_1file.fio --output-format=json --output=/data/storage_tests/output/$GCRNODE/$timestamp/iodepth_write_1file.json
echo "Running iodepth read test...4/6 tests"
fio iodepth_read_1file.fio --output-format=json --output=/data/storage_tests/output/$GCRNODE/$timestamp/iodepth_read_1file.json

echo "Running numjobs write test...5/6 tests"
fio numjobs_write_nfiles.fio --output-format=json --output=/data/storage_tests/output/$GCRNODE/$timestamp/numjobs_write_nfiles.json
echo "Running numjobs read test...6/6 tests"
fio numjobs_read_nfiles.fio --output-format=json --output=/data/storage_tests/output/$GCRNODE/$timestamp/numjobs_read_nfiles.json

echo "Storage tests completed. Results saved in /data/storage_tests/output/$GCRNODE/$timestamp/"