@IsTest
private class NetworkStatusLookupTest {
    @IsTest
    static void returnsNotFoundForMissingKey() {
        NetworkStatusLookup.Request req = new NetworkStatusLookup.Request();
        req.doctorId = 'a06000000000000AAA';
        req.planId = 'a01000000000000AAA';
        List<NetworkStatusLookup.Result> res = NetworkStatusLookup.lookup(new List<NetworkStatusLookup.Request>{ req });
        System.assertEquals(1, res.size());
        System.assertEquals(false, res[0].found);
    }
    @IsTest
    static void handlesBlankIds() {
        NetworkStatusLookup.Request req = new NetworkStatusLookup.Request();
        List<NetworkStatusLookup.Result> res = NetworkStatusLookup.lookup(new List<NetworkStatusLookup.Request>{ req });
        System.assertEquals(false, res[0].found);
    }
}