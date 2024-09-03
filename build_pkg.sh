#Package charts
mkdir -p ./umbrella/charts/
find ./ -name "*.tgz"  -delete   
cd ./

linting_passed=true
for chart in hadoop accumulo zookeeper ingest web; 
do
    echo "linting and packaging $chart..."
    cd $chart 
    lint_result=$(helm lint .)
    if [[ $lint_result == *"ERROR"* ]]; then
        echo $lint_result
        linting_passed=false
    fi
    helm package .
    cp *.tgz ../umbrella/charts/
    cd ..
    echo "---------------------"
done

if ! $linting_passed; then
    echo "One or more charts failed linting, not continuing."
    exit
fi

find ./ -name "*.tgz"  -exec cp {} umbrella/charts/ \;
# Deploy umbrella chart
cd umbrella;
helm lint .
helm package .

cp *.tgz ..