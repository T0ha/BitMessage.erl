-module(bm_types).
-compile([export_all]).
-include("../include/bm.hrl").

-include_lib("eunit/include/eunit.hrl").

%%%
%% Integer packing and unpacking to VariantInt
%%%

encode_varint(Num) when Num < 16#fd ->
    <<Num:8>>;
encode_varint(Num) when Num =< 16#ffff ->
    <<16#fd,Num:16>>;
encode_varint(Num) when Num =< 16#ffffffff ->
    <<16#fe,Num:32>>;
encode_varint(Num) ->
    <<16#ff,Num:64>>.

decode_varint(<<Len:8/big-integer, Rest/bits>>) when Len <16#fd ->
    {Len, Rest};
decode_varint(<<16#fd, Num:16/big-integer, Rest/bits>>) ->
    {Num, Rest};
decode_varint(<<16#fe, Num:32/big-integer, Rest/bits>>) ->
    {Num, Rest};
decode_varint(<<16#ff, Num:64/big-integer, Rest/bits>>) ->
    {Num, Rest}.

%%%
%% String packing and unpacking to VariantStr
%%%

encode_varstr(Str) ->
    Len = length(Str),
    <<(encode_varint(Len))/bytes, (list_to_binary(Str))/bytes>>.

decode_varstr(VStr) ->
    {Len, S} = decode_varint(VStr),
    <<Str:Len/bytes, Rest/bytes>> = S,
    {binary_to_list(Str), Rest}.

decode_varbin(VStr) ->
    {Len, S} = decode_varint(VStr),
    <<Str:Len/bytes, Rest/bytes>> = S,
    {Str, Rest}.

%%%
%% List of any packing and unpacking to VariantIntList
%%%

encode_list(Lst, Fun) ->
    Len = length(Lst),
    BLst = << <<(Fun(I))/bytes>> || I <- Lst>>,
    <<(encode_varint(Len))/bytes, BLst/bytes>>.

decode_list(VLst, Fun) ->
    {Len, S} = decode_varint(VLst),
    decode_list(S, Len, [], Fun).
decode_list(B, 0, A, _Fun) ->
    {A, B};
decode_list(B, C, A, Fun) ->
    {I, R} = Fun(B),
     decode_list(R, C - 1, A ++ [I], Fun).

%%%
%% Network address packing and unpacking to NetworkAddressStruct
%%%

encode_network(#network_address{time=Time, stream=Stream, ip={Ip1,Ip2,Ip3,Ip4}, services=1, port=Port}) ->
    <<Time:64/big-integer, Stream:32/big-integer,1:64/big-integer, 0:10/unit:8-integer,255,255, Ip1, Ip2, Ip3, Ip4, Port:16/big-integer>>.

decode_network(<<Time:64/big-integer, Stream:32/big-integer, 1:64/big-integer, 0:10/unit:8-integer,255,255, Ip1, Ip2, Ip3, Ip4, Port:16/big-integer, R/bytes>>) ->
    {#network_address{time=Time, stream=Stream, ip={Ip1,Ip2,Ip3,Ip4}, port=Port, services=1}, R}.

%%%
%% Helpers
%%%

integer_to_bytes(0) ->
    <<>>;
integer_to_bytes(Num) ->
    <<(integer_to_bytes(Num div 256))/bits, (Num rem 256)/big-integer>>.

binary_to_hexstring(Data) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Data]).

timestamp() ->
    {MSec, Sec, _} = now(),
    trunc(MSec * 1.0e6 + Sec).

pow(Num, 0) when Num >= 0 ->
    1;
pow(Num, Pow) when Num >= 0 ->
    Num * pow(Num, Pow - 1).

%%
%% Test cases
%%

integer_to_bytes_test_() ->
    [
        ?_assert(integer_to_bytes(crypto:bytes_to_integer(<<"TEST">>)) == <<"TEST">>)
        ].

encode_varint_test_() ->
    [
        ?_assert(encode_varint(10) == <<10>>),
        ?_assert(encode_varint(253) == <<16#fd, 00, 253>>),
        ?_assert(encode_varint(252) == <<252>>),
        ?_assert(encode_varint(65535) == <<16#fd,16#ff, 16#ff>>),
        ?_assert(encode_varint(65536) == <<16#fe, 00, 01, 00, 00>>),
        ?_assert(encode_varint(4294967295) == <<16#fe, 16#ff, 16#ff, 16#ff, 16#ff>>),
        ?_assert(encode_varint(4294967296) == <<16#ff, 00, 00, 00, 01, 00, 00, 00, 00>>)
        ].
decode_encode_varint_test_() ->
    [
        ?_assert(decode_varint(encode_varint(10))== {10, <<>>}),
        ?_assert(decode_varint(encode_varint(253))== {253, <<>>}),
        ?_assert(decode_varint(encode_varint(252))== {252, <<>>}),
        ?_assert(decode_varint(encode_varint(65535))== {65535, <<>>}),
        ?_assert(decode_varint(encode_varint(65536))== {65536, <<>>}),
        ?_assert(decode_varint(encode_varint(4294967295))== {4294967295, <<>>}),
        ?_assert(decode_varint(encode_varint(4294967296))== {4294967296, <<>>}),
        ?_assert(decode_varint(<<(encode_varint(4294967296))/bits, <<"test">>/bits>>)== {4294967296, <<"test">>})
        ].

encode_varstr_test_() ->
    [
        ?_assert(encode_varstr("1234567890") == <<10,"1234567890">>)
        ].
decode_encode_varstr_test_() ->
    [
        ?_assert(decode_varstr(encode_varstr("TEST")) == {"TEST", <<>>})
                ].

encode_list_test_() ->
    [
        ?_assert(encode_list([1,2,3,4,5,6,7,8,9,0], fun encode_varint/1) == <<10, 1,2,3,4,5,6,7,8,9,0>>),
        ?_assert(encode_list([1,255,3,4,5,65536,7,8,9,0], fun encode_varint/1) == <<10, 1,(encode_varint(255))/bytes,3,4,5,(encode_varint(65536))/bytes,7,8,9,0>>),
        ?_assert(encode_list(["a", "b"], fun([O]) -> <<O>> end) == <<2, "a", "b">>)
                ].

decode_encode_list_test_() ->
    [
        ?_assert(decode_list(encode_list([1,2,3,4,5,6,7,8,9,0], fun encode_varint/1), fun decode_varint/1) == {[1,2,3,4,5,6,7,8,9,0], <<>>}),
        ?_assert(decode_list(encode_list([1,255,3,4,5,65536,7,8,9,0], fun encode_varint/1), fun decode_varint/1) == {[1,255,3,4,5,65536,7,8,9,0], <<>>}),
        ?_assert(decode_list(encode_list(["a", "b"], fun([O]) -> <<O>> end), fun(<<O:8/integer, R/bytes>>)-> {[O], R}  end) == {["a", "b"], <<>>})
                ].

encode_network_test_() ->
    {ok, IP} = inet:parse_ipv4_address("127.0.0.1"),
    [
        ?_assert(encode_network(#network_address{time=333, stream=1, ip=IP, port=8080, services=1} ) == <<333:64/big-integer, 1:32/big-integer, 1:64/big-integer, 0,0,0,0,0,0,0,0,0,0,255,255, 127,0,0,1, 8080:16/big-integer>>)
                ].

decode_encode_network_test_() ->
    {ok, IP} = inet:parse_ipv4_address("127.0.0.1"),
    [
        ?_assert(decode_network(encode_network(#network_address{time=333, stream=1, ip=IP, port=8080, services=1})) == {#network_address{time=333, stream=1, ip=IP, port=8080, services=1}, <<>>})
                ].
