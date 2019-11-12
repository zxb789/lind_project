deterministicinput=()
nondeterministicinput=()
declare -n arglist='nondeterministicinput'
for var in "$@"; do
    case "$var" in
        -d)
            declare -n arglist='deterministicinput';;
        -*)
            echo "Invalid command line argument $var"
            exit;;
        *)
            for arg in $(cat "$var"); do
                arglist+=("$arg");
            done;;
    esac;
done;

echo ${deterministicinput[@]}
echo ${nondeterministicinput[@]}
totalarray=( "${deterministicinput[@]}" "${nondeterministicinput[@]}" )
echo "Compiling test cases"
for var in "${totalarray[@]}"; do
    varnexe="${var%.*}.nexe";
    x86_64-nacl-gcc-4.4.3 $var -o test_out/$varnexe -std=gnu99;
    varnonexe="${var%.*}";
    gcc $var -o test_out/$varnonexe
done
lindfs cp $PWD/test_out/

echo "Executing nondeterministic test cases"
echo "------------------------------------------------------------------"
for var in "${nondeterministicinput[@]}"; do
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
done
echo "------------------------------------------------------------------"
echo "Executing deterministic test cases"
for var in "${deterministicinput[@]}"; do
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
    echo "Does lindoutput fit regular expression modified regularoutput?"
    python2 "${var%.*}.py" "$lindoutput" "$regularoutput"
done

rm ./test_out/*
lindfs deltree "/tests/test_cases/test_out"
