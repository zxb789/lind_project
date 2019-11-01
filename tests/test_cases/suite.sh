echo "$@"
echo "Compiling test cases"
for var in "$@"; do
    echo $var
    varnexe="${var%.*}.nexe";
    x86_64-nacl-gcc-4.4.3 $var -o test_out/$varnexe -std=gnu99;
    varnonexe="${var%.*}";
    gcc $var -o test_out/$varnonexe
done
lindfs cp $PWD/test_out/

echo "Executing test cases"
for var in "$@"; do
    nexefile="${var%.*}.nexe";
    varnonexe="${var%.*}";
    exec 3>&2
    exec 2> /dev/null
    lindoutput=$(lind "/tests/test_cases/test_out/$nexefile");
    exec 2>&3
    echo "------------------------------------------------------------------"
    echo "lindoutput"
    echo "$lindoutput"
    regularoutput=$(./test_out/$varnonexe)
    echo "regularoutput"
    echo "$regularoutput"
    echo "Does lindoutput == regularoutput?"
    [[ "$lindoutput" = "$regularoutput" ]] && echo TEST PASSED || echo TEST FAILED
    echo $nexefile
done
echo "------------------------------------------------------------------"
rm ./test_out/*
lindfs deltree "/tests/test_cases/test_out"
