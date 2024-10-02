find . -name "*.tgz" -delete
cd datawave-monolith-umbrella
helm dependency update
helm package .
cd ../datawave-stack
helm dependency update
helm package .
cd ..

cp datawave-stack/*.tgz .