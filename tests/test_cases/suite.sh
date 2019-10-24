echo "Compiling test cases"
for var in "$@"; do
    echo $var
    varnexe="${var%.*}.nexe";
    x86_64-nacl-gcc-4.4.3 $var -o test_out/$varnexe -std=gnu99;
    lindfs cp $PWD/test_out/*.nexe
    rm "test_out/$varnexe"
done

echo "Executing test cases"
for var in "$@"; do
    nexefile="${var%.*}.nexe";
    lind "/tests/test_cases/test_out/$nexefile";
    echo "finished"
    lindfs rm "/tests/test_cases/test_out/$nexefile";
done
